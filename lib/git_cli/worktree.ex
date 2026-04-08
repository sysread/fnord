defmodule GitCli.Worktree do
  @moduledoc """
  Shared worktree context for listing, creating, deleting, merging, and
  recreating project worktrees.
  """

  @type worktree_meta :: %{
          optional(atom()) => any()
        }

  @type worktree_entry :: %{
          path: String.t(),
          branch: String.t() | nil,
          base_branch: String.t() | nil,
          merge_status: :merged | :ahead | :diverged | :unknown,
          size: non_neg_integer(),
          exists?: boolean()
        }

  @type recreation_result :: %{
          root: String.t(),
          path: String.t(),
          branch: String.t(),
          meta: worktree_meta()
        }

  @spec default_root(String.t()) :: String.t()
  @doc """
  Returns the default on-disk worktree root for a project under the user's home
  directory.
  """
  def default_root(project) when is_binary(project) do
    Path.join([Settings.get_user_home(), ".fnord", "projects", project, "worktrees"])
  end

  @spec conversation_path(String.t(), String.t()) :: String.t()
  @doc """
  Returns the default path for a conversation worktree within a project.
  """
  def conversation_path(project, conversation_id)
      when is_binary(project) and is_binary(conversation_id) do
    Path.join([default_root(project), conversation_id])
  end

  @spec list(String.t() | nil) :: {:ok, [worktree_entry()]} | {:error, atom()}
  @doc """
  Lists Git worktrees for a repository root and enriches each entry with merge
  status, size, and existence information.
  """
  def list(nil), do: {:error, :not_a_repo}

  def list(root) when is_binary(root) do
    with {:ok, worktrees} <- git_worktree_list(root) do
      {:ok, Enum.map(worktrees, &enrich_worktree(root, &1))}
    end
  end

  @spec create(String.t(), String.t(), String.t() | nil) ::
          {:ok, worktree_entry()} | {:error, atom()}
  @doc """
  Creates a local conversation worktree under the default project conversation
  path.
  """
  def create(project, conversation_id, branch \\ nil) do
    branch = branch || "fnord-#{conversation_id}"

    with {:ok, root} <- project_root(),
         {:ok, base_branch} <- resolve_default_base_branch(root),
         {:ok, path} <- ensure_conversation_path(project, conversation_id),
         {:ok, _out} <- git_worktree_add_branch(root, path, branch, base_branch) do
      {:ok, normalize_worktree_entry(path, branch, base_branch, root)}
    end
  end

  @spec duplicate(String.t(), worktree_meta(), String.t()) ::
          {:ok, worktree_entry()} | {:error, atom()}
  @doc """
  Creates an independent copy of an existing worktree for a forked
  conversation. The new worktree:

    * lives at the default conversation path for `new_conversation_id`
    * is on a fresh branch named `fnord-<new_conversation_id>` that points at
      the source branch's HEAD (so all source commits are inherited along with
      the same merge-base relative to the original base branch)
    * inherits the source's `base_branch` so future merges still target the
      original base (typically `main`), not the source's fnord-* branch
    * carries the source's uncommitted state (modified, deleted, and untracked
      files) replicated via direct file ops, leaving the source worktree
      untouched

  On any failure the new worktree and branch are torn down before returning so
  the caller can fall back cleanly.
  """
  def duplicate(project, source_meta, new_conversation_id)
      when is_binary(project) and is_map(source_meta) and is_binary(new_conversation_id) do
    source_path = meta_path(source_meta)
    source_branch = meta_branch(source_meta)
    source_base_branch = meta_base_branch(source_meta)

    cond do
      not is_binary(source_path) or not File.dir?(source_path) ->
        {:error, :source_missing}

      not is_binary(source_branch) ->
        {:error, :source_branch_missing}

      true ->
        new_branch = "fnord-#{new_conversation_id}"

        with {:ok, root} <- project_root(),
             {:ok, base_branch} <-
               resolve_duplicate_base_branch(root, source_base_branch),
             {:ok, new_path} <- ensure_conversation_path(project, new_conversation_id),
             {:ok, _out} <-
               git_worktree_add_branch(root, new_path, new_branch, source_branch),
             :ok <- overlay_dirty_state(source_path, new_path) do
          {:ok, normalize_worktree_entry(new_path, new_branch, base_branch, root)}
        else
          {:error, reason} ->
            cleanup_failed_duplicate(new_conversation_id, project, new_branch)
            {:error, reason}
        end
    end
  end

  # Prefer the source's recorded base branch so the duplicate keeps merging
  # into the same target. Fall back to the repo default only when the source
  # didn't carry one, which is the legacy-metadata case.
  defp resolve_duplicate_base_branch(_root, base) when is_binary(base), do: {:ok, base}
  defp resolve_duplicate_base_branch(root, _), do: resolve_default_base_branch(root)

  # Replays the source worktree's uncommitted state into the freshly created
  # destination worktree without touching the source. Three name lists drive
  # three file ops, in order: modified tracked files are copied (covering both
  # staged and unstaged edits, including binaries), deletions are propagated so
  # the destination doesn't silently resurrect removed files, and untracked
  # files (excluding .gitignore'd noise) are copied last.
  defp overlay_dirty_state(source_path, dest_path) do
    with {:ok, modified} <- list_modified_tracked(source_path),
         {:ok, deleted} <- list_deleted_tracked(source_path),
         {:ok, untracked} <- list_untracked(source_path),
         :ok <- copy_files(source_path, dest_path, modified),
         :ok <- delete_files(dest_path, deleted),
         :ok <- copy_files(source_path, dest_path, untracked) do
      :ok
    end
  end

  defp list_modified_tracked(path) do
    case git_cmd(path, ["diff", "--name-only", "--diff-filter=ACMRT", "HEAD"]) do
      {:ok, out} -> {:ok, parse_name_list(out)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_deleted_tracked(path) do
    case git_cmd(path, ["ls-files", "--deleted"]) do
      {:ok, out} -> {:ok, parse_name_list(out)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_untracked(path) do
    case git_cmd(path, ["ls-files", "--others", "--exclude-standard"]) do
      {:ok, out} -> {:ok, parse_name_list(out)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_name_list(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp copy_files(_source_root, _dest_root, []), do: :ok

  defp copy_files(source_root, dest_root, [rel | rest]) do
    src = Path.join(source_root, rel)
    dst = Path.join(dest_root, rel)

    with :ok <- File.mkdir_p(Path.dirname(dst)),
         {:ok, _} <- File.copy(src, dst) do
      copy_files(source_root, dest_root, rest)
    else
      _ -> {:error, :copy_failed}
    end
  end

  defp delete_files(_dest_root, []), do: :ok

  defp delete_files(dest_root, [rel | rest]) do
    dst = Path.join(dest_root, rel)

    case File.rm(dst) do
      :ok -> delete_files(dest_root, rest)
      # Tolerate already-absent destinations: the source recorded a deletion
      # against a file that the destination branch never had, so the desired
      # end state (file gone) already holds.
      {:error, :enoent} -> delete_files(dest_root, rest)
      {:error, _} -> {:error, :delete_failed}
    end
  end

  # Best-effort rollback after a failed duplicate. Ignores errors because the
  # caller is already returning the original failure reason and partial state
  # left behind here is preferable to masking the real cause.
  defp cleanup_failed_duplicate(new_conversation_id, project, new_branch) do
    new_path = conversation_path(project, new_conversation_id)

    case project_root() do
      {:ok, root} ->
        if File.exists?(new_path) do
          _ = git_cmd(root, ["worktree", "remove", "--force", new_path])
        end

        _ = git_cmd(root, ["branch", "-D", new_branch])
        :ok

      _ ->
        :ok
    end
  end

  @spec delete(String.t(), String.t()) :: {:ok, any()} | {:error, atom()}
  @doc """
  Removes a worktree at the given path from the repository.
  """
  def delete(root, path) when is_binary(root) and is_binary(path) do
    with {:ok, _out} <- git_worktree_remove(root, path) do
      {:ok, :ok}
    end
  end

  @spec merge(String.t(), String.t()) :: {:ok, any()} | {:error, atom()}
  @doc """
  Merges the checked-out worktree branch into the repository root current
  branch.
  """
  def merge(root, path) when is_binary(root) and is_binary(path) do
    with {:ok, branch} <- git_worktree_branch(root, path),
         {:ok, _out} <- git_cmd(root, ["merge", branch]) do
      {:ok, :ok}
    else
      {:error, :worktree_not_found} -> {:error, :worktree_not_found}
      {:error, :not_a_repo} -> {:error, :not_a_repo}
      _ -> {:error, :merge_failed}
    end
  end

  @spec recreate_conversation_worktree(String.t(), String.t(), worktree_meta()) ::
          {:ok, worktree_meta()} | {:error, atom()}
  @doc """
  Recreates a missing conversation worktree at its default path from stored
  metadata.
  """
  def recreate_conversation_worktree(project, conversation_id, meta)
      when is_binary(project) and is_binary(conversation_id) and is_map(meta) do
    with {:ok, prepared} <- prepare_recreated_worktree(project, conversation_id, meta),
         {:ok, _out} <- git_worktree_add(prepared.root, prepared.path, prepared.branch) do
      {:ok, prepared.meta}
    end
  end

  @spec has_uncommitted_changes?(String.t()) :: boolean()
  @doc """
  Returns true when the worktree at `path` has staged, unstaged, or untracked
  changes that would be lost by a non-force removal.
  """
  def has_uncommitted_changes?(path) when is_binary(path) do
    case git_cmd(path, ["status", "--porcelain"]) do
      {:ok, ""} -> false
      {:ok, _output} -> true
      _ -> false
    end
  end

  @spec has_changes_to_merge?(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          boolean()
  @doc """
  Returns true when the worktree at `path` either has uncommitted changes OR
  has commits on `branch` that are not yet on `base_branch`. This is the
  filesystem/git source of truth for "is there work in this worktree that
  would be lost if we discarded it without merging?"

  Used by Cmd.Ask to gate the end-of-session merge flow without relying on
  agent-side tool tracking, which can miss edits made via cmd_tool, frobs,
  MCP servers, or any code path the heuristic does not enumerate.
  """
  def has_changes_to_merge?(root, path, branch, base_branch)
      when is_binary(root) and is_binary(path) do
    cond do
      not File.dir?(path) ->
        false

      has_uncommitted_changes?(path) ->
        true

      is_binary(branch) and is_binary(base_branch) ->
        branch_ahead_of_base?(root, branch, base_branch)

      true ->
        false
    end
  end

  def has_changes_to_merge?(_root, _path, _branch, _base_branch), do: false

  # Returns true when `branch` has commits that `base_branch` does not. Uses
  # the same fork-point logic as diff_from_fork_point/3 so the answer matches
  # what the merge flow would actually try to land.
  defp branch_ahead_of_base?(root, branch, base_branch) do
    case diff_from_fork_point(root, branch, base_branch) do
      {:ok, diff} -> byte_size(diff) > 0
      _ -> false
    end
  end

  @spec force_delete(String.t(), String.t()) :: {:ok, :ok} | {:error, atom()}
  @doc """
  Removes a worktree even when it contains uncommitted changes.
  """
  def force_delete(root, path) when is_binary(root) and is_binary(path) do
    case File.dir?(path) do
      false ->
        {:error, :worktree_not_found}

      true ->
        case git_cmd(root, ["worktree", "remove", "--force", path]) do
          {:ok, _out} -> {:ok, :ok}
          {:error, :not_a_repo} -> {:error, :not_a_repo}
          _ -> {:error, :git_failed}
        end
    end
  end

  @spec fnord_managed?(String.t(), String.t()) :: boolean()
  @doc """
  Returns true when the given worktree path resolves to the default
  fnord-managed worktree root for the project or to a path beneath it.
  Worktrees at this location are always created by fnord with an `fnord-`
  prefixed branch, so a normalized path check is sufficient to identify
  internally managed worktrees.
  """
  def fnord_managed?(project, path)
      when is_binary(project) and is_binary(path) do
    default_root = Path.expand(default_root(project)) |> String.trim_trailing("/")
    candidate = Path.expand(path) |> String.trim_trailing("/")

    candidate == default_root or String.starts_with?(candidate, default_root <> "/")
  end

  @spec commit_all(String.t(), String.t()) :: {:ok, :ok} | {:error, atom()}
  @doc """
  Stages all changes and commits them in the given worktree directory.
  Returns `{:error, :nothing_to_commit}` when there is nothing to commit.
  """
  def commit_all(path, message) when is_binary(path) and is_binary(message) do
    with {:ok, _} <- git_cmd(path, ["add", "-A"]),
         {:ok, _} <- git_cmd(path, ["commit", "-m", message]) do
      {:ok, :ok}
    else
      {:error, :git_failed} -> {:error, :nothing_to_commit}
      error -> error
    end
  end

  @spec diff_against_base(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, atom()}
  @doc """
  Returns the diff between a base branch and a worktree branch, run from the
  repository root.
  """
  def diff_against_base(root, branch, base_branch)
      when is_binary(root) and is_binary(branch) and is_binary(base_branch) do
    git_cmd(root, ["diff", "#{base_branch}...#{branch}"])
  end

  @spec diff_from_fork_point(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, atom()}
  @doc """
  Returns the diff between the fork point (merge-base) of the worktree branch
  and its base branch. This shows all changes since the branch was created,
  regardless of what has happened on the base branch since.
  """
  def diff_from_fork_point(root, branch, base_branch)
      when is_binary(root) and is_binary(branch) and is_binary(base_branch) do
    with {:ok, merge_base} <- git_cmd(root, ["merge-base", base_branch, branch]) do
      git_cmd(root, ["diff", String.trim(merge_base), branch])
    end
  end

  @spec delete_branch(String.t(), String.t()) :: {:ok, :ok} | {:error, atom()}
  @doc """
  Deletes a local branch from the repository. Uses `-d` (safe delete) which
  refuses to delete unmerged branches.
  """
  def delete_branch(root, branch) when is_binary(root) and is_binary(branch) do
    with {:ok, _} <- git_cmd(root, ["branch", "-d", branch]) do
      {:ok, :ok}
    end
  end

  @spec head_sha(String.t()) :: String.t() | nil
  @doc """
  Returns the short SHA of HEAD in the given repo root, or nil on failure.
  """
  def head_sha(root) when is_binary(root) do
    case git_cmd(root, ["rev-parse", "--short", "HEAD"]) do
      {:ok, out} -> String.trim(out)
      _ -> nil
    end
  end

  @spec revert_head(String.t()) :: {:ok, :ok} | {:error, atom()}
  @doc """
  Reverts the most recent commit in the repository root. Used to undo a merge
  that failed post-merge validation.
  """
  def revert_head(root) when is_binary(root) do
    with {:ok, _} <- git_cmd(root, ["revert", "--no-edit", "HEAD"]) do
      {:ok, :ok}
    end
  end

  @spec force_delete_branch(String.t(), String.t()) :: {:ok, :ok} | {:error, atom()}
  @doc """
  Force-deletes a local branch regardless of merge status.
  """
  def force_delete_branch(root, branch) when is_binary(root) and is_binary(branch) do
    with {:ok, _} <- git_cmd(root, ["branch", "-D", branch]) do
      {:ok, :ok}
    end
  end

  @spec project_root() :: {:ok, String.t()} | {:error, atom()}
  @doc """
  Returns the current repository root or `:not_a_repo` when the process is not
  inside a Git repository.
  """
  def project_root do
    case GitCli.repo_root() do
      nil -> {:error, :not_a_repo}
      root -> {:ok, root}
    end
  end

  @spec normalize_worktree_meta(map()) :: worktree_meta()
  @doc """
  Normalizes stored worktree metadata into the shape expected by the context.
  """
  def normalize_worktree_meta(meta) when is_map(meta) do
    %{path: meta_path(meta), branch: meta_branch(meta), base_branch: meta_base_branch(meta)}
  end

  @spec normalize_worktree_meta_in_parent(map()) :: map()
  @doc """
  Normalizes the worktree sub-map within a parent metadata map, handling both
  atom and string keys for the worktree entry itself. Returns the parent map
  with a normalized :worktree value, or unchanged if no worktree is present.
  """
  def normalize_worktree_meta_in_parent(meta) when is_map(meta) do
    raw = Map.get(meta, :worktree) || Map.get(meta, "worktree")

    case raw do
      nil -> meta
      m when is_map(m) -> Map.put(meta, :worktree, normalize_worktree_meta(m))
    end
  end

  @spec recursive_size(String.t()) :: non_neg_integer()
  def recursive_size(path) when is_binary(path) do
    path
    |> recursive_entries()
    |> Enum.reduce(0, fn entry, acc -> acc + file_size(entry) end)
  end

  defp resolve_default_base_branch(root) do
    case default_base_branch(root) do
      branch when is_binary(branch) -> {:ok, branch}
      nil -> {:error, :invalid_branch}
    end
  end

  defp ensure_conversation_path(project, conversation_id) do
    path = conversation_path(project, conversation_id)

    case File.mkdir_p(default_root(project)) do
      :ok -> {:ok, path}
      _ -> {:error, :git_failed}
    end
  end

  defp ensure_parent_dir(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      _ -> {:error, :git_failed}
    end
  end

  @spec prepare_recreated_worktree(String.t(), String.t(), worktree_meta()) ::
          {:ok, recreation_result()} | {:error, atom()}
  # Preserves the stored worktree path when one exists in metadata, falling
  # back to the default conversation path only for worktrees that were created
  # without an explicit location.
  defp prepare_recreated_worktree(project, conversation_id, meta) do
    stored_path = meta_path(meta)

    target_path =
      if is_binary(stored_path),
        do: stored_path,
        else: conversation_path(project, conversation_id)

    branch = meta_branch(meta)
    base_branch = meta_base_branch(meta)

    with {:ok, root} <- project_root(),
         :ok <- ensure_parent_dir(target_path),
         {:ok, resolved_base_branch} <- resolve_default_base_branch(root),
         {:ok, branch} <- normalize_branch(branch, base_branch || resolved_base_branch) do
      normalized_meta =
        meta
        |> Map.put(:path, target_path)
        |> Map.put(:branch, branch)
        |> Map.put(:base_branch, base_branch || resolved_base_branch)
        |> normalize_worktree_meta()

      {:ok, %{root: root, path: target_path, branch: branch, meta: normalized_meta}}
    end
  end

  defp normalize_worktree_entry(path, branch, base_branch, root) do
    %{
      path: path,
      branch: branch,
      base_branch: base_branch,
      merge_status: merge_status(path, root, branch, base_branch),
      size: recursive_size(path),
      exists?: true
    }
  end

  defp enrich_worktree(root, %{path: path} = entry) do
    branch = Map.get(entry, :branch) || Map.get(entry, "branch")

    base_branch =
      Map.get(entry, :base_branch) || Map.get(entry, "base_branch") || default_base_branch(root)

    Map.merge(entry, %{
      path: path,
      branch: branch,
      base_branch: base_branch,
      merge_status: merge_status(path, root, branch, base_branch),
      size: recursive_size(path),
      exists?: File.dir?(path)
    })
  end

  @spec merge_status(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          :merged | :ahead | :diverged | :unknown
  @doc """
  Returns the merge status of a worktree branch relative to its base branch.
  Returns `:diverged` when the base has commits the worktree branch lacks
  (indicating a rebase is needed).
  """
  def merge_status(path, root, branch, base_branch) do
    cond do
      not File.dir?(path) ->
        :unknown

      is_nil(branch) ->
        :unknown

      is_nil(base_branch) ->
        :unknown

      true ->
        case git_cmd(root, ["merge-base", "--is-ancestor", base_branch, branch]) do
          {:ok, _out} -> :ahead
          _ -> :diverged
        end
    end
  end

  defp git_worktree_list(root) do
    with {:ok, out} <- git_cmd(root, ["worktree", "list", "--porcelain"]) do
      {:ok, parse_worktree_list(out)}
    end
  end

  defp parse_worktree_list(out) do
    out
    |> String.split(~r/\n\s*\n/, trim: true)
    |> Enum.map(&parse_worktree_record/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_worktree_record(record) do
    fields =
      record
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, fn line, acc -> parse_worktree_line(line, acc) end)

    case Map.fetch(fields, :path) do
      {:ok, path} ->
        %{
          path: path,
          branch: Map.get(fields, :branch),
          base_branch: Map.get(fields, :base_branch)
        }

      :error ->
        nil
    end
  end

  defp parse_worktree_line("worktree " <> path, acc), do: Map.put(acc, :path, path)
  defp parse_worktree_line("branch refs/heads/" <> branch, acc), do: Map.put(acc, :branch, branch)
  defp parse_worktree_line("detached", acc), do: Map.put(acc, :branch, nil)
  defp parse_worktree_line("HEAD " <> _head, acc), do: acc
  defp parse_worktree_line(_, acc), do: acc

  # Creates a worktree with a new branch forked from a start point. Used by
  # create/3 for fresh conversation worktrees.
  defp git_worktree_add_branch(root, path, branch, start_point) do
    case git_cmd(root, ["worktree", "add", "--force", "-b", branch, path, start_point]) do
      {:ok, out} -> {:ok, out}
      {:error, :invalid_branch} -> {:error, :invalid_branch}
      {:error, :not_a_repo} -> {:error, :not_a_repo}
      _ -> {:error, :git_failed}
    end
  end

  # Checks out an existing branch into a worktree. Used by
  # recreate_conversation_worktree/3 to restore a previously created worktree.
  defp git_worktree_add(root, path, branch) do
    case git_cmd(root, ["worktree", "add", "--force", path, branch]) do
      {:ok, out} -> {:ok, out}
      {:error, :invalid_branch} -> {:error, :invalid_branch}
      {:error, :not_a_repo} -> {:error, :not_a_repo}
      _ -> {:error, :git_failed}
    end
  end

  defp git_worktree_remove(root, path) do
    case File.dir?(path) do
      false ->
        {:error, :worktree_not_found}

      true ->
        case git_cmd(root, ["worktree", "remove", path]) do
          {:ok, out} -> {:ok, out}
          {:error, :not_a_repo} -> {:error, :not_a_repo}
          _ -> {:error, :git_failed}
        end
    end
  end

  defp git_worktree_branch(root, path) do
    with true <- File.dir?(path) or {:error, :worktree_not_found},
         {:ok, branch} <- git_cmd(root, ["rev-parse", "--abbrev-ref", "HEAD"], cd: path) do
      {:ok, String.trim(branch)}
    end
  end

  defp normalize_branch(nil, base_branch), do: {:ok, base_branch}
  defp normalize_branch(branch, _base_branch) when is_binary(branch), do: {:ok, branch}
  defp normalize_branch(_, _), do: {:error, :invalid_branch}

  @spec default_base_branch(String.t()) :: String.t() | nil
  @doc """
  Returns the default base branch for the repository — either the remote HEAD
  (e.g., `main`) or the current branch as a fallback.
  """
  def default_base_branch(root) when is_binary(root) do
    case repo_default_branch(root) do
      branch when is_binary(branch) -> branch
      nil -> current_branch(root)
    end
  end

  defp repo_default_branch(root) when is_binary(root) do
    with {:ok, out} <- git_cmd(root, ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"]) do
      out
      |> String.trim()
      |> String.replace_prefix("refs/remotes/origin/", "")
      |> case do
        "" -> nil
        branch -> branch
      end
    else
      _ -> nil
    end
  end

  @spec current_branch(String.t()) :: String.t() | nil
  @doc """
  Returns the currently checked-out branch name for the given repo root, or
  nil when HEAD is detached or the branch cannot be determined.
  """
  def current_branch(root) when is_binary(root) do
    with {:ok, branch} <- git_cmd(root, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      branch = String.trim(branch)

      case branch do
        "HEAD" -> nil
        "" -> nil
        valid_branch -> valid_branch
      end
    else
      _ -> nil
    end
  end

  defp git_cmd(root, args, opts \\ []) do
    case System.cmd("git", args, Keyword.merge([cd: root, stderr_to_stdout: true], opts)) do
      {out, 0} -> {:ok, out}
      {_, 128} -> {:error, :not_a_repo}
      {_, 129} -> {:error, :invalid_branch}
      {_, 1} -> {:error, :git_failed}
      {_, _} -> {:error, :git_failed}
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  defp recursive_entries(path) do
    if File.dir?(path) do
      path
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
    else
      []
    end
  end

  defp meta_path(meta), do: Map.get(meta, :path) || Map.get(meta, "path")
  defp meta_branch(meta), do: Map.get(meta, :branch) || Map.get(meta, "branch")
  defp meta_base_branch(meta), do: Map.get(meta, :base_branch) || Map.get(meta, "base_branch")
end

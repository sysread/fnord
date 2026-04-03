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

  defp merge_status(path, root, branch, base_branch) do
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

  defp default_base_branch(root) when is_binary(root) do
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

  defp current_branch(root) when is_binary(root) do
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

defmodule GitCli.Worktree do
  @moduledoc """
  Facade for shared worktree context: listing, creating, deleting,
  merging, and recreating project worktrees.

  Every public function dispatches through `impl/0`, resolved via the
  `:git_worktree` Globals key and defaulting to `GitCli.Worktree.Default`
  (the real git implementation). Tests do NOT point this key at a mock
  by default; tests that script worktree state opt in per test (see
  `Fnord.TestCase.mock_git_worktree/0`). The default implementation
  routes calls to public siblings back through this facade so a test
  double intercepts nested calls (matching `:meck` passthrough
  semantics).
  """

  @type worktree_meta :: %{
          optional(atom()) => any()
        }

  @type worktree_entry :: %{
          path: String.t(),
          branch: String.t() | nil,
          base_branch: String.t() | nil,
          merge_status: :ahead | :diverged | :unknown,
          size: non_neg_integer(),
          exists?: boolean()
        }

  @type recreation_result :: %{
          root: String.t(),
          path: String.t(),
          branch: String.t(),
          meta: worktree_meta()
        }

  @callback default_root(String.t()) :: String.t()
  @callback conversation_path(String.t(), String.t()) :: String.t()
  @callback list(String.t() | nil) :: {:ok, [worktree_entry()]} | {:error, atom()}
  @callback list_raw(String.t() | nil) :: {:ok, [map()]} | {:error, atom()}
  @callback enrich(String.t(), map()) :: map()
  @callback create(String.t(), String.t(), String.t() | nil) ::
              {:ok, worktree_entry()} | {:error, atom()}
  @callback duplicate(String.t(), worktree_meta(), String.t()) ::
              {:ok, worktree_entry()} | {:error, atom()}
  @callback delete(String.t(), String.t()) :: {:ok, any()} | {:error, atom()}
  @callback merge(String.t(), String.t()) :: {:ok, any()} | {:error, atom()}
  @callback recreate_conversation_worktree(String.t(), String.t(), worktree_meta()) ::
              {:ok, worktree_meta()} | {:error, atom()}
  @callback has_uncommitted_changes?(String.t()) :: boolean()
  @callback path_ignored?(String.t(), String.t()) :: boolean()
  @callback has_changes_to_merge?(
              String.t(),
              String.t(),
              String.t() | nil,
              String.t() | nil
            ) :: boolean()
  @callback copy_ignored_files(String.t(), String.t(), [String.t()]) ::
              [{:ok, String.t()} | {:error, String.t(), term}]
  @callback force_delete(String.t(), String.t()) :: {:ok, :ok} | {:error, atom()}
  @callback fnord_managed?(String.t(), String.t()) :: boolean()
  @callback commit_all(String.t(), String.t()) :: {:ok, :ok} | {:error, atom()}
  @callback diff_against_base(String.t(), String.t(), String.t()) ::
              {:ok, String.t()} | {:error, atom()}
  @callback diff_from_fork_point(String.t(), String.t(), String.t()) ::
              {:ok, String.t()} | {:error, atom()}
  @callback delete_branch(String.t(), String.t()) :: {:ok, :ok} | {:error, atom()}
  @callback head_sha(String.t()) :: String.t() | nil
  @callback head_sha_full(String.t()) :: String.t() | nil
  @callback log_oneline(String.t(), String.t(), String.t()) :: [String.t()]
  @callback reset_hard(String.t(), String.t()) :: {:ok, :ok} | {:error, atom()}
  @callback force_delete_branch(String.t(), String.t()) :: {:ok, :ok} | {:error, atom()}
  @callback project_root() :: {:ok, String.t()} | {:error, atom()}
  @callback normalize_worktree_meta(map()) :: worktree_meta()
  @callback normalize_worktree_meta_in_parent(map()) :: map()
  @callback recursive_size(String.t()) :: non_neg_integer()
  @callback merge_status(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
              :ahead | :diverged | :unknown
  @callback default_base_branch(String.t()) :: String.t() | nil
  @callback current_branch(String.t()) :: String.t() | nil

  @doc """
  Returns the default on-disk worktree root for a project under the user's home
  directory.
  """
  @spec default_root(String.t()) :: String.t()
  def default_root(project), do: impl().default_root(project)

  @doc """
  Returns the default path for a conversation worktree within a project.
  """
  @spec conversation_path(String.t(), String.t()) :: String.t()
  def conversation_path(project, conversation_id),
    do: impl().conversation_path(project, conversation_id)

  @doc """
  Lists Git worktrees for a repository root and enriches each entry with merge
  status, size, and existence information.
  """
  @spec list(String.t() | nil) :: {:ok, [worktree_entry()]} | {:error, atom()}
  def list(root), do: impl().list(root)

  @doc """
  Lists Git worktrees for a repository root without enrichment. Returns the
  parsed records as maps containing at least :path and optionally :branch and
  :base_branch. Callers that only need to filter/select should prefer this to
  avoid per-worktree git calls and filesystem walks.
  """
  @spec list_raw(String.t() | nil) :: {:ok, [map()]} | {:error, atom()}
  def list_raw(root), do: impl().list_raw(root)

  @doc """
  Enriches a raw worktree record with merge status, size, and existence
  information.
  """
  @spec enrich(String.t(), map()) :: map()
  def enrich(root, entry), do: impl().enrich(root, entry)

  @doc """
  Creates a local conversation worktree under the default project conversation
  path.
  """
  @spec create(String.t(), String.t(), String.t() | nil) ::
          {:ok, worktree_entry()} | {:error, atom()}
  def create(project, conversation_id, branch \\ nil),
    do: impl().create(project, conversation_id, branch)

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
  @spec duplicate(String.t(), worktree_meta(), String.t()) ::
          {:ok, worktree_entry()} | {:error, atom()}
  def duplicate(project, source_meta, new_conversation_id),
    do: impl().duplicate(project, source_meta, new_conversation_id)

  @doc """
  Removes a worktree at the given path from the repository.
  """
  @spec delete(String.t(), String.t()) :: {:ok, any()} | {:error, atom()}
  def delete(root, path), do: impl().delete(root, path)

  @doc """
  Merges the checked-out worktree branch into the repository root current
  branch. Rebases the branch onto the target first, then fast-forward merges
  for a linear history. Falls back to a regular merge if the rebase fails.
  """
  @spec merge(String.t(), String.t()) :: {:ok, any()} | {:error, atom()}
  def merge(root, path), do: impl().merge(root, path)

  @doc """
  Recreates a missing conversation worktree at its default path from stored
  metadata.
  """
  @spec recreate_conversation_worktree(String.t(), String.t(), worktree_meta()) ::
          {:ok, worktree_meta()} | {:error, atom()}
  def recreate_conversation_worktree(project, conversation_id, meta),
    do: impl().recreate_conversation_worktree(project, conversation_id, meta)

  @doc """
  Returns true when the worktree at `path` has staged, unstaged, or untracked
  changes that would be lost by a non-force removal.
  """
  @spec has_uncommitted_changes?(String.t()) :: boolean()
  def has_uncommitted_changes?(path), do: impl().has_uncommitted_changes?(path)

  @doc """
  Returns true when the file at `path` is ignored by git in the given `root`
  directory (via .gitignore or other exclusion mechanisms). Uses
  `git check-ignore -q` which returns exit 0 for ignored paths, 1 otherwise.
  """
  @spec path_ignored?(String.t(), String.t()) :: boolean()
  def path_ignored?(root, path), do: impl().path_ignored?(root, path)

  @doc """
  Returns true when the worktree at `path` either has uncommitted changes OR
  has commits on `branch` that are not yet on `base_branch`. This is the
  filesystem/git source of truth for "is there work in this worktree that
  would be lost if we discarded it without merging?"

  Used by Cmd.Ask to gate the end-of-session merge flow without relying on
  agent-side tool tracking, which can miss edits made via cmd_tool, frobs,
  MCP servers, or any code path the heuristic does not enumerate.
  """
  @spec has_changes_to_merge?(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          boolean()
  def has_changes_to_merge?(root, path, branch, base_branch),
    do: impl().has_changes_to_merge?(root, path, branch, base_branch)

  @doc """
  Copies a list of relative paths from the worktree to the source repo,
  creating parent directories as needed. Returns a list of results for each
  path attempted.
  """
  @spec copy_ignored_files(String.t(), String.t(), [String.t()]) ::
          [{:ok, String.t()} | {:error, String.t(), term}]
  def copy_ignored_files(source_root, worktree_path, rel_paths),
    do: impl().copy_ignored_files(source_root, worktree_path, rel_paths)

  @doc """
  Removes a worktree even when it contains uncommitted changes.
  """
  @spec force_delete(String.t(), String.t()) :: {:ok, :ok} | {:error, atom()}
  def force_delete(root, path), do: impl().force_delete(root, path)

  @doc """
  Returns true when the given worktree path resolves to the default
  fnord-managed worktree root for the project or to a path beneath it.
  Worktrees at this location are always created by fnord with an `fnord-`
  prefixed branch, so a normalized path check is sufficient to identify
  internally managed worktrees.
  """
  @spec fnord_managed?(String.t(), String.t()) :: boolean()
  def fnord_managed?(project, path), do: impl().fnord_managed?(project, path)

  @doc """
  Stages all changes and commits them in the given worktree directory.
  Returns `{:error, :nothing_to_commit}` when there is nothing to commit.
  """
  @spec commit_all(String.t(), String.t()) :: {:ok, :ok} | {:error, atom()}
  def commit_all(path, message), do: impl().commit_all(path, message)

  @doc """
  Returns the diff between a base branch and a worktree branch, run from the
  repository root.
  """
  @spec diff_against_base(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, atom()}
  def diff_against_base(root, branch, base_branch),
    do: impl().diff_against_base(root, branch, base_branch)

  @doc """
  Returns the diff between the fork point (merge-base) of the worktree branch
  and its base branch. This shows all changes since the branch was created,
  regardless of what has happened on the base branch since.
  """
  @spec diff_from_fork_point(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, atom()}
  def diff_from_fork_point(root, branch, base_branch),
    do: impl().diff_from_fork_point(root, branch, base_branch)

  @doc """
  Deletes a local branch from the repository. Uses `-d` (safe delete) which
  refuses to delete unmerged branches.
  """
  @spec delete_branch(String.t(), String.t()) :: {:ok, :ok} | {:error, atom()}
  def delete_branch(root, branch), do: impl().delete_branch(root, branch)

  @doc """
  Returns the short SHA of HEAD in the given repo root, or nil on failure.
  """
  @spec head_sha(String.t()) :: String.t() | nil
  def head_sha(root), do: impl().head_sha(root)

  @doc """
  Returns the full (unabbreviated) SHA of HEAD, suitable for use as a reset
  target.
  """
  @spec head_sha_full(String.t()) :: String.t() | nil
  def head_sha_full(root), do: impl().head_sha_full(root)

  @doc """
  Returns a list of one-line commit summaries in the range `from..to`,
  newest first. Each entry is a short-sha + subject line.
  """
  @spec log_oneline(String.t(), String.t(), String.t()) :: [String.t()]
  def log_oneline(root, from, to), do: impl().log_oneline(root, from, to)

  @doc """
  Hard-resets the repository at `root` to the given `target` ref. Used to
  revert a fast-forward merge that may have advanced HEAD by multiple commits.
  """
  @spec reset_hard(String.t(), String.t()) :: {:ok, :ok} | {:error, atom()}
  def reset_hard(root, target), do: impl().reset_hard(root, target)

  @doc """
  Force-deletes a local branch regardless of merge status.
  """
  @spec force_delete_branch(String.t(), String.t()) :: {:ok, :ok} | {:error, atom()}
  def force_delete_branch(root, branch), do: impl().force_delete_branch(root, branch)

  @doc """
  Returns the current repository root or `:not_a_repo` when the process is not
  inside a Git repository.
  """
  @spec project_root() :: {:ok, String.t()} | {:error, atom()}
  def project_root(), do: impl().project_root()

  @doc """
  Normalizes stored worktree metadata into the shape expected by the context.
  """
  @spec normalize_worktree_meta(map()) :: worktree_meta()
  def normalize_worktree_meta(meta), do: impl().normalize_worktree_meta(meta)

  @doc """
  Normalizes the worktree sub-map within a parent metadata map, handling both
  atom and string keys for the worktree entry itself. Returns the parent map
  with a normalized :worktree value, or unchanged if no worktree is present.
  """
  @spec normalize_worktree_meta_in_parent(map()) :: map()
  def normalize_worktree_meta_in_parent(meta),
    do: impl().normalize_worktree_meta_in_parent(meta)

  @doc """
  Returns the total size in bytes of all regular files beneath `path`.
  """
  @spec recursive_size(String.t()) :: non_neg_integer()
  def recursive_size(path), do: impl().recursive_size(path)

  @doc """
  Returns the merge status of a worktree branch relative to its base branch.

  Returns `:ahead` when the worktree branch contains the base branch and
  `:unknown` when the worktree path or any branch metadata is unavailable.
  Any other git result is reported as `:diverged` so callers can treat the
  branch as needing manual attention before merge.
  """
  @spec merge_status(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          :ahead | :diverged | :unknown
  def merge_status(path, root, branch, base_branch),
    do: impl().merge_status(path, root, branch, base_branch)

  @doc """
  Returns the default base branch for the repository — either the remote HEAD
  (e.g., `main`) or the current branch as a fallback.
  """
  @spec default_base_branch(String.t()) :: String.t() | nil
  def default_base_branch(root), do: impl().default_base_branch(root)

  @doc """
  Returns the currently checked-out branch name for the given repo root, or
  nil when HEAD is detached or the branch cannot be determined.
  """
  @spec current_branch(String.t()) :: String.t() | nil
  def current_branch(root), do: impl().current_branch(root)

  @spec impl() :: module
  def impl() do
    Services.Globals.get_env(:fnord, :git_worktree) || GitCli.Worktree.Default
  end
end

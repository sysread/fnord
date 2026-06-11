# lib/git_cli.ex

defmodule GitCli do
  @moduledoc """
  Facade for direct git CLI calls.

  Covers repo classification (`is_git_repo?/0`, `worktree_root/0`),
  branch reporting (`current_branch/0`, `default_branch/1`), tree
  enumeration for indexing (`ls_tree/2`, `show_blob/3`), gitignore
  resolution (`ignored_files/1`), and formatted user-facing messages
  (`git_info/0`).

  Note: `default_branch/1` resolves the project's *indexing* branch
  with a strict fallback chain (origin/HEAD → main → master → nil).
  For the looser worktree-root resolution that falls back to the
  current branch, see `GitCli.Worktree.default_base_branch/1`.

  This module is the git-subprocess boundary: every public function
  dispatches through `impl/0`, resolved via the `:git_cli` Globals key
  and defaulting to `GitCli.Default` (the real `System.cmd` wrapper).
  Unlike the lower transport seams, tests do NOT point this key at a
  mock by default - the real implementation stays in place, and tests
  that need to script git state opt in per test (see
  `Fnord.TestCase.mock_git_cli/0`). `GitCli.Default` routes its own
  calls to public siblings back through this facade so a test double
  intercepts nested calls the same way `:meck` passthrough did.
  """

  @callback is_git_repo?() :: boolean()
  @callback is_git_repo_at?(String.t() | nil) :: boolean()
  @callback repo_root() :: String.t() | nil
  @callback is_worktree?() :: boolean()
  @callback worktree_root() :: String.t() | nil
  @callback current_branch() :: String.t() | nil
  @callback git_info() :: String.t()
  @callback ignored_files(String.t() | nil) :: map()
  @callback default_branch(String.t() | nil) :: String.t() | nil
  @callback ls_tree(String.t(), String.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, term}
  @callback show_blob(String.t(), String.t(), String.t()) :: {:ok, binary} | {:error, term}

  @doc """
  Returns true when the effective directory (project root override or
  cwd) is inside a git working tree.
  """
  @spec is_git_repo?() :: boolean()
  def is_git_repo?(), do: impl().is_git_repo?()

  @doc """
  Returns true when the given path is inside a git working tree.
  """
  @spec is_git_repo_at?(String.t() | nil) :: boolean()
  def is_git_repo_at?(path), do: impl().is_git_repo_at?(path)

  @doc """
  Returns the repository toplevel for the effective directory, or nil
  when not in a repo (or git is not installed).
  """
  @spec repo_root() :: String.t() | nil
  def repo_root(), do: impl().repo_root()

  @doc """
  Returns true when the effective directory is inside a git working
  tree. We currently treat any such directory as worktree-aware enough
  for callers using this predicate, including detached HEAD state.
  """
  @spec is_worktree?() :: boolean()
  def is_worktree?(), do: impl().is_worktree?()

  @doc """
  Returns the toplevel of the current worktree, or nil when not in one.
  """
  @spec worktree_root() :: String.t() | nil
  def worktree_root(), do: impl().worktree_root()

  @doc """
  Returns the current branch name for the effective directory, the
  short SHA prefixed with `@` when HEAD is detached, or nil on failure.
  """
  @spec current_branch() :: String.t() | nil
  def current_branch(), do: impl().current_branch()

  @doc """
  Returns a formatted, user-facing description of the current git
  context (branch and root), or a note that the project is not under
  version control.
  """
  @spec git_info() :: String.t()
  def git_info(), do: impl().git_info()

  @doc """
  Returns a map of absolute paths to `true` for every gitignored file
  under `root`. Returns an empty map if root is nil.
  """
  @spec ignored_files(String.t() | nil) :: map()
  def ignored_files(root), do: impl().ignored_files(root)

  @doc """
  Returns the repository's default branch for indexing purposes:

    1. `origin/HEAD` - the remote's declared default (usually main).
    2. Local `main` or `master`, in that order.
    3. `nil` - do not silently fall back to the current branch, since
       that would make `fnord index` on a feature branch index the
       feature branch rather than the project's canonical source.

  Callers fall back to filesystem-mode indexing when this returns nil,
  so the user still gets their working tree indexed; they just won't
  get default-branch semantics.
  """
  @spec default_branch(String.t() | nil) :: String.t() | nil
  def default_branch(root), do: impl().default_branch(root)

  @doc """
  Lists every blob in `branch`'s tree as `{blob_sha, rel_path}` pairs.
  The blob sha is git's content-addressed hash and is stable across
  clones and checkouts, so it's usable as a freshness key for the
  indexer.
  """
  @spec ls_tree(String.t(), String.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, term}
  def ls_tree(root, branch), do: impl().ls_tree(root, branch)

  @doc """
  Returns the content of `rel_path` as it exists on `branch`, or an
  error tuple if git rejects the request (missing file, invalid branch,
  etc.). Content is returned as a binary; binaries that aren't valid
  UTF-8 are still returned — callers decide how to handle them.
  """
  @spec show_blob(String.t(), String.t(), String.t()) :: {:ok, binary} | {:error, term}
  def show_blob(root, branch, rel_path), do: impl().show_blob(root, branch, rel_path)

  @spec impl() :: module
  def impl() do
    Services.Globals.get_env(:fnord, :git_cli) || GitCli.Default
  end
end

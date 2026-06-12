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
  intercepts nested calls, not just top-level entry points.
  """

  @callback is_git_repo?() :: boolean()
  @callback is_git_repo_at?(String.t() | nil) :: boolean()
  @callback repo_root() :: String.t() | nil
  @callback repo_root_at(String.t()) :: {:ok, String.t()} | {:error, :not_a_repo}
  @callback is_worktree?() :: boolean()
  @callback worktree_root() :: String.t() | nil
  @callback current_branch() :: String.t() | nil
  @callback git_info() :: String.t()
  @callback ignored_files(String.t() | nil) :: map()
  @callback default_branch(String.t() | nil) :: String.t() | nil
  @callback ls_tree(String.t(), String.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, term}
  @callback show_blob(String.t(), String.t(), String.t()) :: {:ok, binary} | {:error, term}
  @callback commit_shas(String.t(), String.t()) :: {:ok, [String.t()]} | {:error, term}
  @callback commit_meta(String.t(), String.t()) :: {:ok, commit_meta} | {:error, term}
  @callback commit_numstat(String.t(), String.t()) :: {:ok, commit_numstat} | {:error, term}
  @callback status_short(String.t()) :: {:ok, [String.t()]} | {:error, term}
  @callback primary_root_at(String.t()) :: String.t() | nil
  @callback merge_base(String.t(), String.t(), String.t()) :: {:ok, String.t()} | :error
  @callback diff_stat(String.t(), String.t()) :: {:ok, String.t()} | :error
  @callback log_oneline(String.t(), String.t()) :: {:ok, String.t()} | :error
  @callback verify_commit(String.t(), String.t()) :: {:ok, String.t()} | :error
  @callback fetch_ref(String.t(), String.t(), String.t()) :: {:ok, String.t()} | :error

  @typedoc """
  Parsed metadata for a single commit, as reported by `git show`.
  `committed_at` is the raw unix-epoch string git emits for `%at`.
  """
  @type commit_meta :: %{
          sha: String.t(),
          parent_shas: [String.t()],
          author: String.t(),
          committed_at: String.t(),
          subject: String.t(),
          body: String.t()
        }

  @typedoc """
  Parsed `git show --numstat` output: the list of changed paths and the
  per-file addition/deletion counts. Binary files report 0/0.
  """
  @type commit_numstat ::
          {[String.t()],
           [%{file: String.t(), additions: non_neg_integer, deletions: non_neg_integer}]}

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
  Returns the repository toplevel for the given directory, or
  `{:error, :not_a_repo}` when the path is not inside a git working
  tree. Unlike `repo_root/0`, this ignores the project root override -
  callers use it to resolve the repo that owns an explicit path (e.g. a
  stored worktree) regardless of session state.
  """
  @spec repo_root_at(String.t()) :: {:ok, String.t()} | {:error, :not_a_repo}
  def repo_root_at(path), do: impl().repo_root_at(path)

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

  @doc """
  Lists every commit SHA reachable from `ref`, newest first (rev-list
  order). Used by the commit indexer to enumerate index candidates.
  """
  @spec commit_shas(String.t(), String.t()) :: {:ok, [String.t()]} | {:error, term}
  def commit_shas(root, ref), do: impl().commit_shas(root, ref)

  @doc """
  Returns parsed metadata for a single commit. Errors on unparseable
  output - the most common cause is a literal `\\x1f` byte in a subject
  or body, which collides with the field separator used in the format
  string.
  """
  @spec commit_meta(String.t(), String.t()) :: {:ok, commit_meta} | {:error, term}
  def commit_meta(root, sha), do: impl().commit_meta(root, sha)

  @doc """
  Returns the changed file list and per-file diffstat counts for a
  single commit.
  """
  @spec commit_numstat(String.t(), String.t()) :: {:ok, commit_numstat} | {:error, term}
  def commit_numstat(root, sha), do: impl().commit_numstat(root, sha)

  @doc """
  Returns the raw `git status --short --untracked-files=all` lines for the
  repo at `root`, one entry per changed or untracked file. Used by
  validation-rule changed-file discovery.
  """
  @spec status_short(String.t()) :: {:ok, [String.t()]} | {:error, term}
  def status_short(root), do: impl().status_short(root)

  @doc """
  Returns the primary clone's root for the repo containing `dir`, or nil
  when `dir` is not inside a git work tree. For a linked worktree this is
  the root of the clone the worktree was created from (via `git rev-parse
  --git-common-dir`); for a primary checkout it is the repo root itself.
  Project resolution uses this to map a worktree directory back to the
  configured project root.
  """
  @spec primary_root_at(String.t()) :: String.t() | nil
  def primary_root_at(dir), do: impl().primary_root_at(dir)

  @doc """
  Returns the merge base of two refs at `root`. The review ops below
  return bare `:error` on git failure rather than `{:error, term}`:
  their callers present target-specific context ("failed to resolve
  branch X") and have no use for raw plumbing output.
  """
  @spec merge_base(String.t(), String.t(), String.t()) :: {:ok, String.t()} | :error
  def merge_base(root, ref_a, ref_b), do: impl().merge_base(root, ref_a, ref_b)

  @doc """
  Returns `git diff --stat` output for `range` at `root`.
  """
  @spec diff_stat(String.t(), String.t()) :: {:ok, String.t()} | :error
  def diff_stat(root, range), do: impl().diff_stat(root, range)

  @doc """
  Returns `git log --oneline` output for `range` at `root`.
  """
  @spec log_oneline(String.t(), String.t()) :: {:ok, String.t()} | :error
  def log_oneline(root, range), do: impl().log_oneline(root, range)

  @doc """
  Resolves `ref` to a commit SHA if it exists locally (`rev-parse
  --verify --quiet ref^{commit}`). Never touches the network; pair with
  `fetch_ref/3` to make remote-only refs resolvable via FETCH_HEAD.
  """
  @spec verify_commit(String.t(), String.t()) :: {:ok, String.t()} | :error
  def verify_commit(root, ref), do: impl().verify_commit(root, ref)

  @doc """
  Fetches `ref` from `remote` at `root`. Network-touching: review uses it
  to make never-checked-out branches reviewable, and nothing else should
  reach for it casually.
  """
  @spec fetch_ref(String.t(), String.t(), String.t()) :: {:ok, String.t()} | :error
  def fetch_ref(root, remote, ref), do: impl().fetch_ref(root, remote, ref)

  @spec impl() :: module
  def impl() do
    Services.Globals.get_env(:fnord, :git_cli) || GitCli.Default
  end
end

# lib/git_cli.ex

defmodule GitCli do
  @moduledoc """
  Wrapper for direct git CLI calls.

  Covers repo classification (`is_git_repo?/0`, `worktree_root/0`),
  branch reporting (`current_branch/0`, `default_branch/1`), tree
  enumeration for indexing (`ls_tree/2`, `show_blob/3`), gitignore
  resolution (`ignored_files/1`), and formatted user-facing messages
  (`git_info/0`).

  Note: `default_branch/1` resolves the project's *indexing* branch
  with a strict fallback chain (origin/HEAD → main → master → nil).
  For the looser worktree-root resolution that falls back to the
  current branch, see `GitCli.Worktree.default_base_branch/1`.
  """

  @spec is_git_repo?() :: boolean()
  def is_git_repo? do
    case System.cmd("git", ["rev-parse", "--is-inside-work-tree"],
           cd: effective_git_dir(),
           stderr_to_stdout: true
         ) do
      {"true\n", 0} -> true
      _ -> false
    end
  end

  @spec is_git_repo_at?(String.t() | nil) :: boolean()
  def is_git_repo_at?(nil), do: false

  def is_git_repo_at?(path) when is_binary(path) do
    case System.cmd("git", ["rev-parse", "--is-inside-work-tree"],
           cd: path,
           stderr_to_stdout: true
         ) do
      {"true\n", 0} -> true
      _ -> false
    end
  end

  def repo_root() do
    git = System.find_executable("git")

    if git do
      case System.cmd(git, ["rev-parse", "--show-toplevel"],
             cd: effective_git_dir(),
             stderr_to_stdout: true
           ) do
        {out, 0} -> String.trim(out)
        _ -> nil
      end
    else
      nil
    end
  end

  # We currently treat any effective directory inside a git working tree as
  # worktree-aware enough for callers using this predicate, including detached
  # HEAD state.
  def is_worktree? do
    is_git_repo?()
  end

  def worktree_root() do
    if is_worktree?() do
      case System.cmd("git", ["rev-parse", "--show-toplevel"],
             cd: effective_git_dir(),
             stderr_to_stdout: true
           ) do
        {result, 0} -> String.trim(result)
        _ -> nil
      end
    else
      nil
    end
  end

  # Branch reporting follows the same effective directory semantics as the
  # other repo and worktree helpers in this module.
  @spec current_branch() :: String.t() | nil
  def current_branch() do
    git = System.find_executable("git")

    if git do
      case System.cmd(git, ["rev-parse", "--abbrev-ref", "HEAD"],
             cd: effective_git_dir(),
             stderr_to_stdout: true
           ) do
        {out, 0} ->
          case String.trim(out) do
            "HEAD" ->
              case System.cmd(git, ["rev-parse", "--short", "HEAD"],
                     cd: effective_git_dir(),
                     stderr_to_stdout: true
                   ) do
                {sha, 0} -> "@" <> String.trim(sha)
                _ -> nil
              end

            branch ->
              branch
          end

        _ ->
          nil
      end
    else
      nil
    end
  end

  @spec branch_name(String.t(), String.t()) :: String.t() | nil
  defp branch_name(git, dir) do
    case System.cmd(git, ["rev-parse", "--abbrev-ref", "HEAD"],
           cd: dir,
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case String.trim(out) do
          "HEAD" ->
            case System.cmd(git, ["rev-parse", "--short", "HEAD"],
                   cd: dir,
                   stderr_to_stdout: true
                 ) do
              {sha, 0} -> "@" <> String.trim(sha)
              _ -> nil
            end

          branch ->
            branch
        end

      _ ->
        nil
    end
  end

  @spec git_info() :: String.t()
  def git_info() do
    git = System.find_executable("git")

    if git do
      root =
        case System.cmd(git, ["rev-parse", "--show-toplevel"],
               cd: effective_git_dir(),
               stderr_to_stdout: true
             ) do
          {out, 0} -> String.trim(out)
          _ -> nil
        end

      branch =
        if root do
          branch_name(git, effective_git_dir())
        end

      if root && branch do
        """
        You are working in a git repository.
        The current branch is `#{branch}`.
        The git root is `#{root}`.
        """
      else
        "Note: this project is not under git version control."
      end
    else
      "Note: git executable not found on PATH."
    end
  end

  @spec effective_git_dir() :: String.t()
  defp effective_git_dir() do
    Settings.get_project_root_override() || File.cwd!()
  end

  @spec ignored_files(String.t() | nil) :: map()
  @doc """
  Returns an empty map if root is nil, otherwise behaves as before.
  """
  def ignored_files(nil), do: %{}

  def ignored_files(root) when is_binary(root) do
    case System.cmd("git", ["ls-files", "--others", "--ignored", "--exclude-standard"],
           cd: root,
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(&Path.absname(&1, root))
        |> Map.new(&{&1, true})

      _ ->
        %{}
    end
  end

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
  def default_branch(nil), do: nil

  def default_branch(root) when is_binary(root) do
    key = {__MODULE__, :default_branch, root}

    case :persistent_term.get(key, :miss) do
      :miss ->
        result = resolve_default_branch(root)
        :persistent_term.put(key, result)
        result

      cached ->
        cached
    end
  end

  # Forks 2-4 git subprocesses (is_git_repo_at? + symbolic-ref, then
  # rev-parse probes for main/master). Called per file under the index
  # scan's async_stream via Source.hash and Source.exists?, so without
  # the persistent_term wrapper above this is O(N) fork/exec round
  # trips per pass - minutes of scan time on a thousand-file repo.
  # Cached for the BEAM's lifetime: the branch tip doesn't advance
  # during a single fnord invocation and the mode decision must stay
  # stable across a scan.
  defp resolve_default_branch(root) do
    cond do
      not is_git_repo_at?(root) -> nil
      branch = remote_head(root) -> branch
      branch_exists?(root, "main") -> "main"
      branch_exists?(root, "master") -> "master"
      true -> nil
    end
  end

  defp remote_head(root) do
    case System.cmd("git", ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"],
           cd: root,
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case out |> String.trim() |> String.replace_prefix("refs/remotes/origin/", "") do
          "" -> nil
          branch -> branch
        end

      _ ->
        nil
    end
  end

  defp branch_exists?(root, branch) do
    case System.cmd("git", ["rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"],
           cd: root,
           stderr_to_stdout: true
         ) do
      {_, 0} -> true
      _ -> false
    end
  end

  @doc """
  Lists every blob in `branch`'s tree as `{blob_sha, rel_path}` pairs.
  The blob sha is git's content-addressed hash and is stable across
  clones and checkouts, so it's usable as a freshness key for the
  indexer.
  """
  @spec ls_tree(String.t(), String.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, term}
  def ls_tree(root, branch) when is_binary(root) and is_binary(branch) do
    case System.cmd(
           "git",
           ["ls-tree", "-r", "--full-tree", "--format=%(objectname)\t%(path)", branch],
           cd: root,
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        entries =
          out
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn line ->
            case String.split(line, "\t", parts: 2) do
              [sha, path] when byte_size(sha) > 0 and byte_size(path) > 0 -> [{sha, path}]
              _ -> []
            end
          end)

        {:ok, entries}

      {err, _} ->
        {:error, String.trim(err)}
    end
  end

  @doc """
  Returns the content of `rel_path` as it exists on `branch`, or an
  error tuple if git rejects the request (missing file, invalid branch,
  etc.). Content is returned as a binary; binaries that aren't valid
  UTF-8 are still returned — callers decide how to handle them.
  """
  @spec show_blob(String.t(), String.t(), String.t()) :: {:ok, binary} | {:error, term}
  def show_blob(root, branch, rel_path)
      when is_binary(root) and is_binary(branch) and is_binary(rel_path) do
    case System.cmd("git", ["show", "#{branch}:#{rel_path}"], cd: root, stderr_to_stdout: false) do
      {out, 0} -> {:ok, out}
      {err, _} -> {:error, String.trim(err)}
    end
  end
end

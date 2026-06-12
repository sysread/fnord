defmodule GitCli.Default do
  @moduledoc """
  Real implementation of the `GitCli` behaviour: thin wrappers over
  `System.cmd("git", ...)`. See `GitCli` for the public contract and
  per-function documentation.

  Calls to public siblings go back through the `GitCli` facade rather
  than locally, so a test double installed on the `:git_cli` Globals
  key intercepts nested calls, not just top-level entry points.
  """

  @behaviour GitCli

  @impl GitCli
  def is_git_repo? do
    case System.cmd("git", ["rev-parse", "--is-inside-work-tree"],
           cd: effective_git_dir(),
           stderr_to_stdout: true
         ) do
      {"true\n", 0} -> true
      _ -> false
    end
  end

  @impl GitCli
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

  @impl GitCli
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

  @impl GitCli
  def repo_root_at(path) when is_binary(path) do
    case System.cmd("git", ["rev-parse", "--show-toplevel"],
           cd: path,
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, String.trim(out)}
      _ -> {:error, :not_a_repo}
    end
  end

  @impl GitCli
  def is_worktree? do
    GitCli.is_git_repo?()
  end

  @impl GitCli
  def worktree_root() do
    if GitCli.is_worktree?() do
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
  @impl GitCli
  def current_branch() do
    git = System.find_executable("git")

    if git do
      branch_name(git, effective_git_dir())
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

  @impl GitCli
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

  @impl GitCli
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

  @impl GitCli
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
      not GitCli.is_git_repo_at?(root) -> nil
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

  @impl GitCli
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

  @impl GitCli
  def show_blob(root, branch, rel_path)
      when is_binary(root) and is_binary(branch) and is_binary(rel_path) do
    case System.cmd("git", ["show", "#{branch}:#{rel_path}"], cd: root, stderr_to_stdout: false) do
      {out, 0} -> {:ok, out}
      {err, _} -> {:error, String.trim(err)}
    end
  end

  @impl GitCli
  def commit_shas(root, ref) when is_binary(root) and is_binary(ref) do
    case System.cmd("git", ["rev-list", ref],
           cd: root,
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, String.split(String.trim(out), "\n", trim: true)}
      {err, status} -> {:error, {status, err}}
    end
  end

  # The \x1f (ASCII unit separator) field delimiter is chosen as the byte
  # least likely to appear in commit text; a literal \x1f in a subject or
  # body still breaks the parse, which surfaces as :invalid_commit_metadata.
  @impl GitCli
  def commit_meta(root, sha) when is_binary(root) and is_binary(sha) do
    case System.cmd(
           "git",
           [
             "show",
             "--quiet",
             "--format=%H\x1f%P\x1f%an\x1f%at\x1f%s\x1f%b",
             sha
           ],
           cd: root,
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        case String.trim(out) do
          "" ->
            {:error, :empty_commit_output}

          line ->
            case String.split(line, "\x1f") do
              [commit_sha, parents, author, committed_at, subject, body] ->
                {:ok,
                 %{
                   sha: commit_sha,
                   parent_shas: String.split(parents, " ", trim: true),
                   author: author,
                   committed_at: committed_at,
                   subject: subject,
                   body: body
                 }}

              _ ->
                {:error, :invalid_commit_metadata}
            end
        end

      {error, status} ->
        {:error, {status, error}}
    end
  end

  @impl GitCli
  def commit_numstat(root, sha) when is_binary(root) and is_binary(sha) do
    case System.cmd(
           "git",
           ["show", "--numstat", "--format=", sha],
           cd: root,
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        {files, stats} =
          out
          |> String.split("\n", trim: true)
          |> Enum.reduce({[], []}, fn line, {files, stats} ->
            cond do
              line == "" ->
                {files, stats}

              String.contains?(line, "\t") ->
                case String.split(line, "\t") do
                  [adds, dels, path] ->
                    {additions, deletions} = parse_numstat_counts(adds, dels)

                    {[path | files],
                     [%{file: path, additions: additions, deletions: deletions} | stats]}

                  _ ->
                    {files, stats}
                end

              true ->
                {files, stats}
            end
          end)

        {:ok, {Enum.reverse(Enum.uniq(files)), Enum.reverse(stats)}}

      {error, status} ->
        {:error, {status, error}}
    end
  end

  @impl GitCli
  def status_short(root) when is_binary(root) do
    case System.cmd("git", ["status", "--short", "--untracked-files=all"],
           cd: root,
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, String.split(out, "\n", trim: true)}
      {error, status} -> {:error, {status, error}}
    end
  end

  @impl GitCli
  def primary_root_at(dir) when is_binary(dir) do
    case System.cmd("git", ["rev-parse", "--is-inside-work-tree"],
           cd: dir,
           stderr_to_stdout: true
         ) do
      {"true\n", 0} ->
        case System.cmd("git", ["rev-parse", "--git-common-dir"],
               cd: dir,
               stderr_to_stdout: true
             ) do
          # --git-common-dir answers with the primary clone's .git directory;
          # its parent is the primary root. Git may answer relative to `dir`
          # (a bare ".git" when dir IS the primary root), so expand against
          # dir to keep the contract absolute.
          {out, 0} -> out |> String.trim() |> Path.dirname() |> Path.expand(dir)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @impl GitCli
  def merge_base(root, ref_a, ref_b) do
    run_git(root, ["merge-base", ref_a, ref_b])
  end

  @impl GitCli
  def diff_stat(root, range) do
    run_git(root, ["diff", "--stat", range])
  end

  @impl GitCli
  def log_oneline(root, range) do
    run_git(root, ["log", "--oneline", range])
  end

  @impl GitCli
  def verify_commit(root, ref) do
    run_git(root, ["rev-parse", "--verify", "--quiet", ref <> "^{commit}"])
  end

  @impl GitCli
  def fetch_ref(root, remote, ref) do
    run_git(root, ["fetch", remote, ref])
  end

  # Shared runner for the review ops: trimmed stdout on success, bare :error
  # on any failure (see the facade docs for why these don't return reasons).
  @spec run_git(String.t(), [String.t()]) :: {:ok, String.t()} | :error
  defp run_git(root, args) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      _ -> :error
    end
  end

  @spec parse_numstat_counts(String.t(), String.t()) ::
          {non_neg_integer(), non_neg_integer()}
  defp parse_numstat_counts(adds, dels) do
    {parse_numstat_int(adds), parse_numstat_int(dels)}
  end

  # Numstat reports "-" for binary files; treat anything non-numeric as 0.
  @spec parse_numstat_int(String.t()) :: non_neg_integer()
  defp parse_numstat_int(value) do
    case Integer.parse(value) do
      {count, _} when count >= 0 -> count
      _ -> 0
    end
  end
end

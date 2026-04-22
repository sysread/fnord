defmodule Store.Project.Source do
  @moduledoc """
  Abstraction over "where does this project's source come from?"

  Git projects index the default branch's tree: enumeration comes from
  `git ls-tree`, content from `git show <branch>:<path>`, and the
  freshness key is the git blob SHA. A user on a feature branch with
  WIP changes still sees the default-branch snapshot indexed, which is
  what the rest of the codebase (search, file_notes, reviewer) expects
  as its ground truth.

  Non-git projects fall back to the filesystem: enumeration via `find`
  on `source_root`, content via `File.read`, freshness via sha256 of
  the file contents.

  The mode is decided once per project (`mode/1`) and all reads/hashes
  go through this module so callers never branch on git-ness
  themselves.
  """

  alias Store.Project

  @type mode :: :git | :fs

  @type listing_entry :: %{
          rel_path: String.t(),
          abs_path: String.t(),
          hash: String.t() | nil
        }

  @doc """
  Returns `:git` when the project's source_root is a git repo whose
  default branch can be resolved, and `:fs` otherwise.
  """
  @spec mode(Project.t() | nil) :: mode
  def mode(nil), do: :fs
  def mode(%Project{source_root: nil}), do: :fs

  def mode(%Project{source_root: root}) do
    case GitCli.default_branch(root) do
      branch when is_binary(branch) -> :git
      _ -> :fs
    end
  end

  @doc """
  Returns the default branch name when the project is in `:git` mode,
  nil otherwise. `GitCli.default_branch/1` is NOT cached today - it forks
  2-4 git subprocesses per call (`symbolic-ref`, then `rev-parse` probes
  for main/master). Callers under async_stream should memoize if the
  overhead matters; `cached_ls_tree/2` in this module uses the returned
  branch as part of its cache key but does not cache the branch lookup
  itself.
  """
  @spec default_branch(Project.t()) :: String.t() | nil
  def default_branch(%Project{source_root: nil}), do: nil
  def default_branch(%Project{source_root: root}), do: GitCli.default_branch(root)

  @doc """
  Enumerates all source items in the project as `%{rel_path, abs_path,
  hash}` maps. In git mode the list reflects the default branch's tree
  (blob SHA as hash); in fs mode it reflects the working tree's
  filesystem walk (sha256 as hash, computed lazily by callers — the
  listing returns `hash: nil` for fs mode).

  Callers are responsible for applying project-level excludes and
  text/binary filtering; this function only answers "what source
  items exist?".
  """
  @spec list(Project.t()) :: [listing_entry()]
  def list(project) do
    case mode(project) do
      :git -> list_git(project)
      :fs -> list_fs(project)
    end
  end

  defp list_git(project) do
    case cached_ls_tree(project.source_root, default_branch(project)) do
      {:ok, entries} ->
        Enum.map(entries, fn {sha, rel_path} ->
          %{
            rel_path: rel_path,
            abs_path: Path.expand(rel_path, project.source_root),
            hash: sha
          }
        end)

      {:error, _} ->
        []
    end
  end

  # ls-tree is invoked from `list/1` (enumeration) and, indirectly, from
  # `hash/2` and `exists?/2`. All three run under indexing's async_stream
  # - that's O(N) subprocess forks on a large project if we don't
  # memoize. Cached for the BEAM's lifetime: a single fnord invocation
  # is short-lived and the branch tip won't advance during an index
  # run. Both successes and failures are cached - a transient git
  # failure shouldn't turn into O(N) retries inside the worker fan-out.
  defp cached_ls_tree(root, branch) do
    key = cache_key(root, branch)

    case :persistent_term.get(key, :miss) do
      :miss ->
        result = GitCli.ls_tree(root, branch)
        :persistent_term.put(key, result)
        result

      cached ->
        cached
    end
  end

  defp cache_key(root, branch), do: {__MODULE__, :ls_tree, root, branch}

  # Point-lookup view of the ls-tree output, cached separately from the
  # list so `hash/2` and `exists?/2` do O(1) Map operations instead of
  # an Enum.find over every tracked blob. index_status calls those two
  # per file under async_stream, so without this the scan is O(N^2) in
  # tree size. Cache both successes and failures - a failed lookup once
  # should not retry N times under fan-out.
  defp cached_path_map(root, branch) do
    key = path_map_key(root, branch)

    case :persistent_term.get(key, :miss) do
      :miss ->
        result =
          case cached_ls_tree(root, branch) do
            {:ok, entries} ->
              {:ok, Map.new(entries, fn {sha, rel_path} -> {rel_path, sha} end)}

            {:error, _} = err ->
              err
          end

        :persistent_term.put(key, result)
        result

      cached ->
        cached
    end
  end

  defp path_map_key(root, branch), do: {__MODULE__, :path_map, root, branch}

  defp list_fs(project) do
    # fs listing intentionally doesn't pre-compute hashes. Working-tree
    # hashing requires reading every file and only the entries that
    # pass text/exclude filters will actually need it - we let callers
    # drive the read via `hash/2`.
    case project.source_root do
      nil ->
        []

      root ->
        args = ["-c", "(find #{root} -type f || true) | sort"]

        case System.cmd("sh", args, stderr_to_stdout: true) do
          {output, 0} ->
            output
            |> String.split("\n", trim: true)
            |> Enum.reject(&String.ends_with?(&1, ": Permission denied"))
            |> Enum.map(fn abs_path ->
              %{
                rel_path: Path.relative_to(abs_path, root),
                abs_path: Path.absname(abs_path, root),
                hash: nil
              }
            end)

          _ ->
            []
        end
    end
  end

  @doc """
  Returns the content of `rel_path` under the project's active source.
  Routed to `git show` in git mode, `File.read` in fs mode.
  """
  @spec read(Project.t() | nil, String.t()) :: {:ok, binary} | {:error, term}
  def read(nil, _rel_path), do: {:error, :no_project}
  def read(%Project{source_root: nil}, _rel_path), do: {:error, :no_source_root}

  def read(project, rel_path) do
    case mode(project) do
      :git ->
        GitCli.show_blob(project.source_root, default_branch(project), rel_path)

      :fs ->
        File.read(Path.expand(rel_path, project.source_root))
    end
  end

  @doc """
  Returns the freshness hash for `rel_path` under the project's active
  source. In git mode that's the blob SHA (fetched from ls-tree if
  available, else computed via `git hash-object`). In fs mode, sha256
  of the file's current content.
  """
  @spec hash(Project.t() | nil, String.t() | nil) :: {:ok, String.t()} | {:error, term}
  def hash(nil, _rel_path), do: {:error, :no_project}
  def hash(_project, nil), do: {:error, :no_rel_path}
  def hash(%Project{source_root: nil}, _rel_path), do: {:error, :no_source_root}

  def hash(project, rel_path) do
    case mode(project) do
      :git ->
        # Cheapest path: ask git for the blob SHA on the default branch.
        case cached_path_map(project.source_root, default_branch(project)) do
          {:ok, map} ->
            case Map.fetch(map, rel_path) do
              {:ok, sha} -> {:ok, sha}
              :error -> {:error, :not_in_tree}
            end

          {:error, reason} ->
            {:error, reason}
        end

      :fs ->
        path = Path.expand(rel_path, project.source_root)

        case File.read(path) do
          {:ok, content} -> {:ok, sha256(content)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  True when `rel_path` still exists under the project's active source.
  Used by `delete_missing_files` to scope deletion correctly: a file
  present in the working tree but not on the default branch *is*
  "missing" for our purposes.
  """
  @spec exists?(Project.t() | nil, String.t() | nil) :: boolean
  def exists?(nil, _rel_path), do: false
  def exists?(_project, nil), do: false
  def exists?(%Project{source_root: nil}, _rel_path), do: false

  def exists?(project, rel_path) do
    case mode(project) do
      :git ->
        case cached_path_map(project.source_root, default_branch(project)) do
          {:ok, map} -> Map.has_key?(map, rel_path)
          _ -> false
        end

      :fs ->
        File.exists?(Path.expand(rel_path, project.source_root))
    end
  end

  defp sha256(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end
end

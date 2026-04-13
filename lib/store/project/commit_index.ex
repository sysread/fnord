defmodule Store.Project.CommitIndex do
  @moduledoc """
  Manages semantic index data for git commits within a project.

  Commit index data lives alongside the other project-scoped semantic indexes,
  but under its own root so commit entries remain isolated from file and
  conversation storage.
  """

  alias Store.Project
  alias Store.Project.CommitDocument

  @type metadata :: %{optional(String.t()) => any}

  @type commit_metadata :: %{optional(String.t()) => any}

  @type commit_record :: %{
          sha: String.t(),
          parent_shas: [String.t()],
          subject: String.t(),
          body: String.t(),
          author: String.t(),
          committed_at: String.t() | DateTime.t() | non_neg_integer(),
          changed_files: [String.t()],
          diffstat: String.t() | [map()],
          embedding_model: String.t() | nil,
          last_indexed_ts: non_neg_integer()
        }

  @type commit_status :: %{
          new: [commit_record()],
          stale: [commit_record()],
          deleted: [String.t()]
        }

  @index_dir "commits/index"
  @embeddings_filename "embeddings.json"
  @metadata_filename "metadata.json"

  @spec root(Project.t()) :: String.t()
  def root(%Project{store_path: store_path}) do
    Path.join(store_path, @index_dir)
  end

  @spec path_for(Project.t(), String.t()) :: String.t()
  def path_for(project, sha) do
    project
    |> root()
    |> Path.join(sha)
  end

  @doc """
  Classifies commit index entries into `new`, `stale`, and `deleted`.

  A commit is stale when the stored embedding model, document version, or
  canonical commit document hash differs from the current values.
  """
  @spec index_status(Project.t()) :: commit_status()
  def index_status(%Project{} = project) do
    source_commits = list_source_commits(project)

    indexed_shas =
      project
      |> root()
      |> Path.join("*/#{@metadata_filename}")
      |> Path.wildcard()
      |> Enum.map(&Path.dirname/1)
      |> Enum.map(&Path.basename/1)
      |> MapSet.new()

    source_by_sha = Map.new(source_commits, &{&1.sha, &1})
    source_shas = MapSet.new(Map.keys(source_by_sha))
    new_shas = MapSet.difference(source_shas, indexed_shas)
    deleted_shas = MapSet.difference(indexed_shas, source_shas)

    stale_commits =
      source_commits
      |> Enum.filter(fn commit ->
        case read_metadata(project, commit.sha) do
          {:ok, metadata} -> stale_commit?(commit, metadata)
          _ -> false
        end
      end)

    %{
      new: Enum.map(new_shas, &Map.fetch!(source_by_sha, &1)),
      stale: stale_commits,
      deleted: MapSet.to_list(deleted_shas)
    }
  end

  @doc """
  Writes embeddings and metadata for a commit.

  The embeddings are stored in `embeddings.json` and the metadata in
  `metadata.json` under the commit's index directory.
  """
  @spec write_embeddings(Project.t(), String.t(), any, metadata()) :: :ok | {:error, term()}
  def write_embeddings(%Project{} = project, sha, embeddings, metadata) do
    dir = path_for(project, sha)

    with :ok <- File.mkdir_p(dir),
         :ok <- write_json(Path.join(dir, @embeddings_filename), embeddings),
         :ok <- write_json(Path.join(dir, @metadata_filename), metadata) do
      :ok
    end
  end

  @doc """
  Reads embeddings and metadata for a commit.
  """
  @spec read_embeddings(Project.t(), String.t()) ::
          {:ok, %{embeddings: any, metadata: metadata()}} | {:error, term()}
  def read_embeddings(%Project{} = project, sha) do
    dir = path_for(project, sha)
    embeddings_path = Path.join(dir, @embeddings_filename)
    metadata_path = Path.join(dir, @metadata_filename)

    with {:ok, embeddings} <- read_json(embeddings_path),
         {:ok, metadata} <- read_json(metadata_path) do
      {:ok, %{embeddings: embeddings, metadata: metadata}}
    end
  end

  @doc """
  Reads only the metadata for a commit index entry.
  """
  @spec read_metadata(Project.t(), String.t()) :: {:ok, metadata()} | {:error, term()}
  def read_metadata(%Project{} = project, sha) do
    project
    |> path_for(sha)
    |> Path.join(@metadata_filename)
    |> read_json()
  end

  @doc """
  Enumerates all indexed commits, yielding `{sha, embeddings, metadata}`.
  """
  @spec all_embeddings(Project.t()) :: Enumerable.t()
  def all_embeddings(%Project{} = project) do
    project
    |> root()
    |> Path.join("*/#{@embeddings_filename}")
    |> Path.wildcard()
    |> Stream.map(fn path ->
      sha = path |> Path.dirname() |> Path.basename()

      case {read_json(path), read_metadata(project, sha)} do
        {{:ok, embeddings}, {:ok, metadata}} -> {sha, embeddings, metadata}
        _ -> nil
      end
    end)
    |> Stream.reject(&is_nil/1)
  end

  @doc """
  Deletes the index entry for the given commit SHA.
  """
  @spec delete(Project.t(), String.t()) :: :ok
  def delete(%Project{} = project, sha) do
    project
    |> path_for(sha)
    |> File.rm_rf!()

    :ok
  end

  @doc """
  Builds the canonical commit document and metadata payload used for indexing.
  """
  @spec build_metadata(%{
          sha: binary(),
          parent_shas: [binary()],
          subject: binary(),
          body: binary(),
          author: binary(),
          committed_at: binary() | non_neg_integer() | DateTime.t(),
          changed_files: [binary()],
          diffstat: binary() | [map()]
        }) :: %{document: binary(), metadata: metadata()}
  def build_metadata(commit) do
    {document, doc_hash} = CommitDocument.build(commit)

    metadata = %{
      "sha" => commit.sha,
      "parent_shas" => commit.parent_shas,
      "subject" => commit.subject,
      "body" => commit.body,
      "author" => commit.author,
      "committed_at" => commit.committed_at,
      "changed_files" => commit.changed_files,
      "diffstat" => commit.diffstat,
      "embedding_model" => commit.embedding_model,
      "index_format_version" => CommitDocument.version(),
      "doc_hash" => doc_hash,
      "last_indexed_ts" => commit.last_indexed_ts
    }

    %{document: document, metadata: metadata}
  end

  defp stale_commit?(commit, metadata) do
    %{metadata: current_metadata} = build_metadata(commit)

    metadata["embedding_model"] != current_metadata["embedding_model"] or
      metadata["index_format_version"] != current_metadata["index_format_version"] or
      metadata["doc_hash"] != current_metadata["doc_hash"]
  end

  @spec list_source_commits(Project.t()) :: [map()]
  defp list_source_commits(%Project{} = project) do
    case git_root(project) do
      nil -> []
      root -> git_commits(root)
    end
  end

  @spec git_root(Project.t()) :: String.t() | nil
  defp git_root(%Project{source_root: nil}), do: nil

  defp git_root(%Project{} = project) do
    if GitCli.is_git_repo_at?(project.source_root) do
      project.source_root
    else
      nil
    end
  end

  @spec get_commit_meta(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defp get_commit_meta(root, sha) do
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

  @spec get_commit_changes(String.t(), String.t()) ::
          {:ok, {[String.t()], [map()]}} | {:error, term()}
  defp get_commit_changes(root, sha) do
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

  @spec git_commits(String.t()) :: [map()]
  defp git_commits(root) do
    # Use HEAD to enumerate the reachable commit history. This is robust across
    # repos without a configured remote HEAD or when detached.
    ref = "HEAD"

    shas =
      case System.cmd("git", ["rev-list", ref],
             cd: root,
             stderr_to_stdout: true
           ) do
        {out, 0} -> String.split(String.trim(out), "\n", trim: true)
        _ -> []
      end

    shas
    |> Util.async_stream(fn sha ->
      with {:ok, meta} <- get_commit_meta(root, sha),
           {:ok, {changed_files, diffstat}} <- get_commit_changes(root, sha) do
        %{
          sha: meta.sha,
          parent_shas: meta.parent_shas,
          author: meta.author,
          committed_at: meta.committed_at,
          subject: meta.subject,
          body: meta.body,
          changed_files: changed_files,
          diffstat: diffstat,
          embedding_model: nil,
          last_indexed_ts: 0
        }
      else
        _ -> nil
      end
    end)
    |> Enum.reduce([], fn
      {:ok, nil}, acc -> acc
      {:ok, commit}, acc -> [commit | acc]
    end)
    |> Enum.reverse()
  end

  @spec parse_numstat_counts(String.t(), String.t()) :: {non_neg_integer(), non_neg_integer()}
  defp parse_numstat_counts(adds, dels) do
    {parse_numstat_int(adds), parse_numstat_int(dels)}
  end

  @spec parse_numstat_int(String.t()) :: non_neg_integer()
  defp parse_numstat_int(value) do
    case Integer.parse(value) do
      {count, _} when count >= 0 -> count
      _ -> 0
    end
  end

  @spec write_json(String.t(), any) :: :ok | {:error, term()}
  defp write_json(path, data) do
    case SafeJson.encode(data) do
      {:ok, json} -> File.write(path, json)
      error -> error
    end
  end

  @spec read_json(String.t()) :: {:ok, any} | {:error, term()}
  defp read_json(path) do
    case File.read(path) do
      {:ok, contents} -> SafeJson.decode(contents)
      error -> error
    end
  end
end

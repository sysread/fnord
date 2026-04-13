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
    case GitCli.is_git_repo?() do
      true -> project.source_root
      false -> nil
    end
  end

  # Resolve the repository's default branch and prefer it for commit discovery.
  # Falls back to HEAD if the default branch cannot be determined.
  @spec git_commits(String.t()) :: [map()]
  defp git_commits(root) do
    ref =
      case default_branch(root) do
        {:ok, branch_or_ref} -> branch_or_ref
        :error -> "HEAD"
      end

    with {log_output, 0} <-
           System.cmd(
             "git",
             [
               "log",
               "--first-parent",
               "--date=iso-strict",
               "--name-status",
               "--numstat",
               "--format=%H%x1f%P%x1f%an%x1f%ad%x1f%s%x1f%b%x1e",
               ref
             ],
             cd: root,
             stderr_to_stdout: true
           ) do
      parse_commits(log_output)
    else
      _ -> []
    end
  end

  @spec default_branch(String.t()) :: {:ok, String.t()} | :error
  defp default_branch(root) do
    case origin_head_ref(root) do
      {:ok, origin_ref} ->
        {:ok, origin_ref}

      :error ->
        case remote_show_origin_head(root) do
          {:ok, branch} ->
            cond do
              remote_branch_exists?(root, branch) -> {:ok, "origin/" <> branch}
              local_branch_exists?(root, branch) -> {:ok, branch}
              true -> fallback_branch(root)
            end

          :error ->
            fallback_branch(root)
        end
    end
  end

  @spec origin_head_ref(String.t()) :: {:ok, String.t()} | :error
  defp origin_head_ref(root) do
    case System.cmd("git", ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
           cd: root,
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        ref = String.trim(out)

        if String.starts_with?(ref, "origin/") do
          {:ok, ref}
        else
          :error
        end

      _ ->
        :error
    end
  end

  @spec remote_show_origin_head(String.t()) :: {:ok, String.t()} | :error
  defp remote_show_origin_head(root) do
    case System.cmd("git", ["remote", "show", "origin"], cd: root, stderr_to_stdout: true) do
      {out, 0} ->
        branch =
          out
          |> String.split("\n")
          |> Enum.find_value(fn line ->
            case String.trim(line) do
              "HEAD branch: " <> b when byte_size(b) > 0 -> String.trim(b)
              _ -> nil
            end
          end)

        if is_binary(branch) and branch != "" do
          {:ok, branch}
        else
          :error
        end

      _ ->
        :error
    end
  end

  @spec fallback_branch(String.t()) :: {:ok, String.t()} | :error
  defp fallback_branch(root) do
    cond do
      remote_branch_exists?(root, "main") -> {:ok, "origin/main"}
      local_branch_exists?(root, "main") -> {:ok, "main"}
      remote_branch_exists?(root, "master") -> {:ok, "origin/master"}
      local_branch_exists?(root, "master") -> {:ok, "master"}
      true -> :error
    end
  end

  @spec local_branch_exists?(String.t(), String.t()) :: boolean
  defp local_branch_exists?(root, branch) do
    case System.cmd("git", ["show-ref", "--verify", "--quiet", "refs/heads/" <> branch],
           cd: root,
           stderr_to_stdout: true
         ) do
      {_out, 0} -> true
      _ -> false
    end
  end

  @spec remote_branch_exists?(String.t(), String.t()) :: boolean
  defp remote_branch_exists?(root, branch) do
    case System.cmd("git", ["show-ref", "--verify", "--quiet", "refs/remotes/origin/" <> branch],
           cd: root,
           stderr_to_stdout: true
         ) do
      {_out, 0} -> true
      _ -> false
    end
  end

  @spec parse_commits(String.t()) :: [map()]
  defp parse_commits(output) do
    output
    |> String.split("\x1e", trim: true)
    |> Enum.flat_map(&parse_commit_chunk/1)
  end

  @spec parse_commit_chunk(String.t()) :: [map()]
  defp parse_commit_chunk(chunk) do
    case String.split(chunk, "\n", trim: true) do
      [header | change_lines] ->
        case String.split(header, "\x1f") do
          [sha, parents, author, committed_at, subject, body] ->
            {changed_files, diffstat} = parse_commit_changes(change_lines)

            [
              %{
                sha: sha,
                parent_shas: String.split(parents, " ", trim: true),
                author: author,
                committed_at: committed_at,
                subject: subject,
                body: body,
                changed_files: changed_files,
                diffstat: diffstat,
                embedding_model: nil,
                last_indexed_ts: 0
              }
            ]

          _ ->
            []
        end

      _ ->
        []
    end
  end

  @spec parse_commit_changes([String.t()]) :: {[String.t()], [map()]}
  defp parse_commit_changes(lines) do
    lines
    |> Enum.reduce({[], []}, fn line, {files, stats} ->
      cond do
        line == "" ->
          {files, stats}

        String.starts_with?(line, " ") ->
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
          case String.split(line, "\t", parts: 2) do
            [status, path] -> {[path | files], [%{file: path, status: status} | stats]}
            [path] -> {[path | files], stats}
            _ -> {files, stats}
          end
      end
    end)
    |> then(fn {files, stats} -> {Enum.reverse(Enum.uniq(files)), Enum.reverse(stats)} end)
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

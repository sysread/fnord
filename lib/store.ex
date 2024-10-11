defmodule Store do
  @moduledoc """
  This module provides the functionality for storing and retrieving embeddings
  and metadata for files.
  """

  defstruct [:project, :path]

  @doc """
  Get the path to the store root directory.
  """
  def home() do
    "#{System.get_env("HOME")}/.fnord"
  end

  @doc """
  Create a new `Store` struct.
  """
  def new(project) do
    File.mkdir_p!(home())

    path = Path.join(home(), project)
    File.mkdir_p!(path)

    %Store{
      project: project,
      path: path
    }
  end

  @doc """
  Permanently deletes the specified project's index directory and all its
  contents.
  """
  def delete_project(store) do
    File.rm_rf!(store.path)
  end

  @doc """
  Permanently deletes the specified file from the store. Note that this is
  _only_ exposed for the sake of testing.
  """
  def delete_file(store, file) do
    path = get_entry_path(store, file)
    File.rm_rf!(path)
  end

  @doc """
  Permanently delete any files that are indexed but no longer exist on disk.
  """
  def delete_missing_files(store, root) do
    store
    |> list_files()
    |> Enum.each(fn file ->
      cond do
        !File.exists?(file) -> delete_file(store, file)
        # There was a bug allowing git-ignored files to be indexed
        Git.is_ignored?(file, root) -> delete_file(store, file)
        true -> :ok
      end
    end)
  end

  defp get_key(file_path) do
    full_path = Path.expand(file_path)
    :crypto.hash(:sha256, full_path) |> Base.encode16(case: :lower)
  end

  defp get_entry_path(store, file_path) do
    Path.join(store.path, get_key(file_path))
  end

  @doc """
  Get the metadata for the specified file. Returns `{:ok, data}` if the file
  exists, or `{:error, :not_found}` if it does not. The structure of the
  metadata is as follows:

  ```
  %{
    file: "path/to/file.ext",
    hash: "DEADBEEF",
    timestamp: "2021-01-01T00:00:00Z",
    fnord_path: "path/to/store/FEEBDAED"
  }
  ```
  """
  def info(store, file) do
    with path = get_entry_path(store, file),
         file = Path.join(path, "metadata.json"),
         {:ok, data} <- File.read(file),
         {:ok, meta} <- Jason.decode(data) do
      {:ok, Map.put(meta, "fnord_path", path)}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Get the hash for the specified file. Returns `{:ok, hash}` if the file
  exists, or `{:error, :not_found}` if it does not.
  """
  def get_hash(store, file) do
    Store.info(store, file)
    |> case do
      {:ok, data} -> Map.get(data, "hash")
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Get the summary for the specified file. Returns `{:ok, summary}` if the file
  exists, or `{:error, :not_found}` if it does not.
  """
  def get_summary(store, file) do
    with path = get_entry_path(store, file),
         file = Path.join(path, "summary"),
         {:ok, summary} <- File.read(file) do
      {:ok, summary}
    else
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Get the embeddings for the specified file. Returns `{:ok, embeddings}` if the
  file exists, or `{:error, :not_found}` if it does not. Note that if the input
  file was greater than 8192 tokens, the embeddings will be split into multiple
  chunks.
  """
  def get_embeddings(store, file) do
    with {:ok, meta} <- Store.info(store, file) do
      path = Map.get(meta, "fnord_path")

      embeddings =
        Path.join(path, "embedding_*.json")
        |> Path.wildcard()
        |> Enum.map(&File.read!(&1))
        |> Enum.map(&Jason.decode!(&1))

      {:ok, embeddings}
    else
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Get the metadata, summary, and embeddings for the specified file. Returns
  `{:ok, info}` if the file exists, or `{:error, :not_found}` if it does not.

  The structure of the returned `info` is as follows:

  ```
  %{
    file: "path/to/file.ext",
    hash: "DEADBEEF",
    timestamp: "2021-01-01T00:00:00Z",
    summary: "AI-generated summary of the file",
    embeddings: [
      [0.1, 0.2, 0.3, ...],
      [0.4, 0.5, 0.6, ...],
      ...
    ]
  }
  ```
  """
  def get(store, file) do
    with {:ok, meta} <- Store.info(store, file),
         {:ok, summary} <- get_summary(store, file),
         {:ok, embeddings} <- get_embeddings(store, file) do
      info =
        meta
        |> Map.put("summary", summary)
        |> Map.put("embeddings", embeddings)

      {:ok, info}
    else
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Store the metadata, summary, and embeddings for the specified file. If the
  file already exists in the store, it will be overwritten.
  """
  def put(store, file, hash, summary, embeddings) do
    path = get_entry_path(store, file)

    # Delete the existing directory if it exists
    File.rm_rf!(path)

    # Recreate the subject file dir under the project dir
    File.mkdir_p!(path)

    # Write the metadata to a separate file
    metadata =
      Jason.encode!(%{
        file: Path.expand(file),
        hash: hash,
        timestamp: DateTime.utc_now()
      })

    Path.join(path, "metadata.json") |> File.write!(metadata)

    # Write the summary to a separate file
    Path.join(path, "summary") |> File.write!(summary)

    # Write each chunk of embeddings to separate files
    embeddings
    |> Enum.with_index()
    |> Enum.each(fn {embedding, chunk_no} ->
      entry = Jason.encode!(embedding)
      Path.join(path, "embedding_#{chunk_no}.json") |> File.write!(entry)
    end)
  end

  @doc """
  List all projects in the store. Returns a list of project names.
  """
  def list_projects() do
    Path.wildcard(Path.join(home(), "*"))
    |> Enum.map(fn path -> Path.basename(path) end)
  end

  @doc """
  List all indexed files in the project. Returns a list of absolute, expanded,
  file paths.
  """
  def list_files(store) do
    Path.wildcard(Path.join(store.path, "*"))
    |> Enum.map(fn path ->
      path
      |> Path.join("metadata.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.get("file")
    end)
  end

  # Computes the cosine similarity between two vectors
  def cosine_similarity(vec1, vec2) do
    dot_product = Enum.zip(vec1, vec2) |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
    magnitude1 = :math.sqrt(Enum.reduce(vec1, 0.0, fn x, acc -> acc + x * x end))
    magnitude2 = :math.sqrt(Enum.reduce(vec2, 0.0, fn x, acc -> acc + x * x end))

    if magnitude1 == 0.0 or magnitude2 == 0.0 do
      0.0
    else
      dot_product / (magnitude1 * magnitude2)
    end
  end
end

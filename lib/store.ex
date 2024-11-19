defmodule Store do
  @moduledoc """
  This module provides the functionality for storing and retrieving embeddings
  and metadata for files.
  """

  require Logger

  defstruct [:project, :path]

  @doc """
  Create a new `Store` struct.
  """
  def new(project) do
    home = Settings.home()

    File.mkdir_p!(home)

    path = Path.join(home, project)
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
  def delete_missing_files(store, root, callback \\ fn -> nil end) do
    store
    |> list_files()
    |> Enum.each(fn file ->
      cond do
        !File.exists?(file) ->
          delete_file(store, file)
          callback.()

        # There was a bug allowing git-ignored files to be indexed
        Git.is_ignored?(file, root) ->
          delete_file(store, file)
          callback.()

        true ->
          :ok
      end
    end)
  end

  @doc """
  Get the key for the specified file, which is based on the file's full path
  and is used as the directory name for the file's metadata.
  """
  def get_key(file_path) do
    full_path = Path.expand(file_path)
    :crypto.hash(:sha256, full_path) |> Base.encode16(case: :lower)
  end

  @doc """
  Get the path to the directory containing the metadata for the specified file.
  """
  def get_entry_path(store, file_path) do
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
  Check if the specified file has a summary file. Returns `true` if the file exists,
  or `false` if it does not.
  """
  def has_summary?(store, file) do
    store
    |> get_entry_path(file)
    |> Path.join("summary")
    |> File.exists?()
  end

  @doc """
  Check if the specified file has an outline outline. Returns `true` if the file
  exists, or `false` if it does not.
  """
  def has_outline?(store, file) do
    store
    |> get_entry_path(file)
    |> Path.join("outline")
    |> File.exists?()
  end

  @doc """
  Check if the specified file has embeddings. Returns `true` if any exist,
  `false` otherwise.
  """
  def has_embeddings?(store, file) do
    with {:ok, meta} <- Store.info(store, file),
         path = Map.get(meta, "fnord_path"),
         files = Path.join(path, "embedding_*.json") |> Path.wildcard() do
      Enum.any?(files, &File.exists?/1)
    end
  end

  @doc """
  Get the summary for the specified file. Returns `{:ok, summary}` if the file
  exists, or `{:error, :not_found}` if it does not.
  """
  def get_summary(store, file) do
    read_file(store, file, :summary)
  end

  @doc """
  Get the symbol/ctags style outline for the specified file. Returns `{:ok,
  outline}` if the file exists, or `{:error, :not_found}` if it does not.
  """
  def get_outline(store, file) do
    read_file(store, file, :outline)
  end

  @doc """
  Get the embeddings for the specified file. Returns `{:ok, embeddings}` if the
  file exists, or `{:error, :not_found}` if it does not. Note that if the input
  file was greater than 8192 tokens, the embeddings will be split into multiple
  chunks.
  """
  def get_embeddings(store, file) do
    with {:ok, meta} <- Store.info(store, file),
         path = Map.get(meta, "fnord_path"),
         files = Path.join(path, "embedding_*.json") |> Path.wildcard() do
      files
      |> Enum.map(fn file ->
        with {:ok, data} <- File.read(file),
             {:ok, embedding} <- Jason.decode(data) do
          embedding
        else
          {:error, reason} ->
            Logger.error("Error reading embedding: <#{file}> #{reason}")
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> then(&{:ok, &1})
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
         {:ok, embeddings} <- get_embeddings(store, file),
         {:ok, outline} <- get_outline(store, file),
         {:ok, contents} <- File.read(file) do
      info =
        meta
        |> Map.put("summary", summary)
        |> Map.put("embeddings", embeddings)
        |> Map.put("outline", outline)
        |> Map.put("contents", contents)

      {:ok, info}
    else
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  Store the metadata, summary, and embeddings for the specified file. If the
  file already exists in the store, it will be overwritten.
  """
  def put(store, file, hash, summary, outline, embeddings) do
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

    # Write the outline to a separate file
    Path.join(path, "outline") |> File.write!(outline)

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
    Path.wildcard(Path.join(Settings.home(), "*"))
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(fn path -> Path.basename(path) end)
  end

  @doc """
  List all indexed files in the project. Returns a list of absolute, expanded,
  file paths.
  """
  def list_files(store) do
    Path.wildcard(Path.join(store.path, "*"))
    |> Enum.map(fn path -> Path.join(path, "metadata.json") end)
    |> Enum.filter(&File.exists?/1)
    |> Enum.map(fn path ->
      path
      |> File.read!()
      |> Jason.decode!()
      |> Map.get("file")
    end)
  end

  defp read_file(store, file, kind) do
    case kind do
      :outline -> get_entry_path(store, file) |> Path.join("outline")
      :summary -> get_entry_path(store, file) |> Path.join("summary")
    end
    |> File.read()
    |> case do
      {:ok, content} ->
        {:ok, content}

      {:error, reason} ->
        {:error,
         "unable to read #{kind} for #{file} (you may need to reindex #{store.project}): #{inspect(reason)}"}
    end
  end
end

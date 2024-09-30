defmodule Store do
  defstruct [:project, :path]

  @home "#{System.get_env("HOME")}/.fnord"

  def new(project) do
    File.mkdir_p!(@home)

    path = Path.join(@home, project)
    File.mkdir_p!(path)

    %Store{
      project: project,
      path: path
    }
  end

  def delete_project(store) do
    File.rm_rf!(store.path)
  end

  def delete_file(store, file) do
    path = get_entry_path(store, file)
    File.rm_rf!(path)
  end

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

  def get_hash(store, file) do
    Store.info(store, file)
    |> case do
      {:ok, data} -> Map.get(data, "hash")
      {:error, :not_found} -> {:error, :not_found}
    end
  end

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

  def get(store, file) do
    with {:ok, meta} <- Store.info(store, file) do
      path = Map.get(meta, "fnord_path")
      summary = Path.join(path, "summary") |> File.read!()

      embeddings =
        Path.join(path, "embedding_*.json")
        |> Path.wildcard()
        |> Enum.map(&File.read!(&1))
        |> Enum.map(&Jason.decode!(&1))

      info =
        meta
        |> Map.put("summary", summary)
        |> Map.put("embeddings", embeddings)

      {:ok, info}
    else
      {:error, :not_found} -> {:error, :not_found}
    end
  end

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

  def list_projects() do
    Path.wildcard(Path.join(@home, "*"))
    |> Enum.map(fn path -> Path.basename(path) end)
  end

  # Computes the cosine similarity between two vectors
  def cosine_similarity(vec1, vec2) do
    dot_product = Enum.zip(vec1, vec2) |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
    magnitude1 = :math.sqrt(Enum.reduce(vec1, 0.0, fn x, acc -> acc + x * x end))
    magnitude2 = :math.sqrt(Enum.reduce(vec2, 0.0, fn x, acc -> acc + x * x end))
    dot_product / (magnitude1 * magnitude2)
  end
end

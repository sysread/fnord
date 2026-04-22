defmodule Store.Project.Entry.Metadata do
  defstruct [:store_path, :source_file]

  @filename "metadata.json"

  @behaviour Store.Project.EntryFile

  @impl Store.Project.EntryFile
  def new(entry_path, source_file) do
    %__MODULE__{
      store_path: Path.join(entry_path, @filename),
      source_file: source_file
    }
  end

  @impl Store.Project.EntryFile
  def exists?(file), do: file |> store_path() |> File.exists?()

  @impl Store.Project.EntryFile
  def store_path(file), do: file.store_path

  @impl Store.Project.EntryFile
  def read(file) do
    file.store_path
    |> File.read()
    |> case do
      {:ok, contents} -> SafeJson.decode(contents)
      error -> error
    end
  end

  @impl Store.Project.EntryFile
  def write(file, data \\ %{}) do
    data = if is_map(data), do: data, else: %{}
    rel_path = Map.get(data, :rel_path) || Map.get(data, "rel_path")
    # Callers that know the content hash upfront (git mode passes the blob
    # SHA straight through from ls-tree) should set `hash:` in `data`.
    # Otherwise we fall back to hashing the working-tree file so this
    # function remains usable from test / tooling call sites that bypass
    # the Source-aware save pipeline.
    hash = Map.get(data, :hash) || Map.get(data, "hash") || mkhash(file.source_file)
    # `embedding_dim` is recorded here so `is_stale?` can answer the
    # "does the stored vector match the current model?" question without
    # opening the embeddings file on every scan. Written only when the
    # caller has a dim to persist - older stores upgrade lazily on their
    # first post-upgrade scan (see Entry.embedding_dim_is_current?/2).
    embedding_dim = Map.get(data, :embedding_dim) || Map.get(data, "embedding_dim")

    base = %{
      file: rel_path || file.source_file,
      timestamp: DateTime.utc_now(),
      hash: hash
    }

    payload =
      case embedding_dim do
        dim when is_integer(dim) -> Map.put(base, :embedding_dim, dim)
        _ -> base
      end

    payload
    |> SafeJson.encode()
    |> case do
      {:ok, json} -> File.write(file.store_path, json)
      error -> error
    end
  end

  defp mkhash(file) do
    :crypto.hash(:sha256, File.read!(file))
    |> Base.encode16(case: :lower)
  end
end

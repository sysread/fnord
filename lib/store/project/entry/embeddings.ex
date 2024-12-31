defmodule Store.Project.Entry.Embeddings do
  defstruct [:store_path, :source_file]

  @filename "embeddings.json"

  @behaviour Store.Project.EntryFile

  @impl Store.Project.EntryFile
  def new(entry_path, source_file) do
    entry = %__MODULE__{
      store_path: Path.join(entry_path, @filename),
      source_file: source_file
    }

    if has_old_style_embeddings?(entry) do
      entry
      |> upgrade_old_style_embeddings()
      |> case do
        {:error, reason} ->
          UI.warn("Error upgrading embeddings format", "#{entry.source_file}: #{inspect(reason)}")

        _ ->
          nil
      end
    end

    entry
  end

  @impl Store.Project.EntryFile
  def store_path(entry), do: entry.store_path

  @impl Store.Project.EntryFile
  def exists?(entry), do: File.exists?(entry.store_path)

  @impl Store.Project.EntryFile
  def read(entry) do
    entry
    |> store_path()
    |> File.read()
    |> case do
      {:ok, contents} -> Jason.decode(contents)
      error -> error
    end
  end

  @impl Store.Project.EntryFile
  def write(entry, embeddings) do
    # Embeddings used to be stored separately for each chunk of the file (when
    # the file was too large for the model to process in one go). This is no
    # longer the case, so we need to remove the old embedding files, which were
    # named embeddings_N.json.
    entry.store_path
    |> Path.dirname()
    |> Path.join("embeddings_*.json")
    |> Path.wildcard()
    |> Enum.each(&File.rm_rf!/1)

    embeddings
    # For each dimension, find the maximum value across all embeddings. This
    # isn't necessarily the _most_ accurate, but it selects the highest rating
    # for each dimension found in the file, which should be reasonable for
    # semantic searching.
    |> Enum.zip_with(&Enum.max/1)
    |> Jason.encode()
    |> case do
      {:ok, json} -> File.write(entry.store_path, json)
      error -> error
    end
  end

  defp get_old_style_embeddings(entry) do
    entry.store_path
    |> Path.dirname()
    |> Path.join("embedding_*.json")
    |> Path.wildcard()
  end

  defp has_old_style_embeddings?(entry) do
    count =
      entry
      |> get_old_style_embeddings()
      |> Enum.count()

    count > 0
  end

  defp upgrade_old_style_embeddings(entry) do
    UI.debug("Upgrading embeddings format", entry.source_file)

    # First, find all of the old-style embeddings files.
    embeddings_files = get_old_style_embeddings(entry)

    # Next, read the contents of each file and combine them, selecting the max
    # value for each position.
    combined_embeddings =
      embeddings_files
      |> Enum.map(&File.read!/1)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.zip_with(&Enum.max/1)

    # Write the combined embeddings to the new file.
    with {:ok, json} <- Jason.encode(combined_embeddings),
         :ok <- File.write(entry.store_path, json) do
      # Lastly, delete the old embeddings files.
      embeddings_files
      |> Enum.each(fn path ->
        UI.debug("Deleting old-style embeddings file", path)
        File.rm_rf!(path)
      end)

      :ok
    else
      error ->
        UI.warn("Error upgrading embeddings format", inspect(error))
        {:error, error}
    end
  end
end

defmodule Store.Metadata do
  defstruct [:store_path, :source_file]

  @filename "metadata.json"

  @behaviour Store.EntryFile

  @impl Store.EntryFile
  def new(entry_path, source_file) do
    %__MODULE__{
      store_path: Path.join(entry_path, @filename),
      source_file: source_file
    }
  end

  @impl Store.EntryFile
  def exists?(file), do: file |> store_path() |> File.exists?()

  @impl Store.EntryFile
  def store_path(file), do: file.store_path

  @impl Store.EntryFile
  def read(file) do
    file.store_path
    |> File.read()
    |> case do
      {:ok, contents} -> Jason.decode(contents)
      error -> error
    end
  end

  @impl Store.EntryFile
  def write(file, _) do
    %{
      file: file.source_file,
      timestamp: DateTime.utc_now(),
      hash: mkhash(file.source_file)
    }
    |> Jason.encode()
    |> case do
      {:ok, json} -> File.write(file.store_path, json)
      error -> error
    end
  end

  defp mkhash(file) do
    :crypto.hash(:sha256, File.read!(file)) |> Base.encode16(case: :lower)
  end
end

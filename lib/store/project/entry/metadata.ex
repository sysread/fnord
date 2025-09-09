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
      {:ok, contents} -> Jason.decode(contents)
      error -> error
    end
  end

  @impl Store.Project.EntryFile
  def write(file, data \\ %{}) do
    rel_path =
      case data do
        %{} -> Map.get(data, :rel_path) || Map.get(data, "rel_path")
        _ -> nil
      end

    %{
      file: rel_path || file.source_file,
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
    :crypto.hash(:sha256, File.read!(file))
    |> Base.encode16(case: :lower)
  end
end

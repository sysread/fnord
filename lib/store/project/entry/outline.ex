defmodule Store.Project.Entry.Outline do
  defstruct [:store_path, :source_file]

  @filename "outline"

  @behaviour Store.Project.EntryFile

  @impl Store.Project.EntryFile
  def new(entry_path, source_file) do
    %__MODULE__{
      store_path: Path.join(entry_path, @filename),
      source_file: source_file
    }
  end

  @impl Store.Project.EntryFile
  def store_path(file), do: file.store_path

  @impl Store.Project.EntryFile
  def exists?(file), do: file |> store_path() |> File.exists?()

  @impl Store.Project.EntryFile
  def read(file), do: file |> store_path() |> File.read()

  @impl Store.Project.EntryFile
  def write(file, data) when is_binary(data), do: file |> store_path() |> File.write(data)
  def write(_, _), do: {:error, :unsupported}
end

defmodule Store.Summary do
  defstruct [:store_path, :source_file]

  @filename "summary"

  @behaviour Store.EntryFile

  @impl Store.EntryFile
  def new(entry_path, source_file) do
    %__MODULE__{
      store_path: Path.join(entry_path, @filename),
      source_file: source_file
    }
  end

  @impl Store.EntryFile
  def store_path(file), do: file.store_path

  @impl Store.EntryFile
  def exists?(file), do: file.store_path |> File.exists?()

  @impl Store.EntryFile
  def read(file), do: file.store_path |> File.read()

  @impl Store.EntryFile
  def write(file, data) when is_binary(data), do: file.store_path |> File.write(data)
  def write(_, _), do: {:error, :unsupported}
end

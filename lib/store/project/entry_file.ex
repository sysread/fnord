defmodule Store.Project.EntryFile do
  @callback new(entry_file_path :: String.t(), source_file_path :: String.t()) :: struct()
  @callback store_path(struct()) :: String.t()
  @callback exists?(struct()) :: boolean
  @callback read(struct()) :: {:ok, any()} | {:error, any()}
  @callback write(struct(), any()) :: :ok | {:error, any()}
end

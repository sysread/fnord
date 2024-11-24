defmodule Cmd.Torch do
  @doc """
  Permanently deletes the project from the store.
  """
  def run(_opts) do
    Store.new()
    |> Store.delete_project()
  end
end

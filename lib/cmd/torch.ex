defmodule Cmd.Torch do
  @doc """
  Permanently deletes the project from the store.
  """
  def run(_opts) do
    Store.get_project()
    |> Store.Project.delete()
  end
end

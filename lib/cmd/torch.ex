defmodule Cmd.Torch do
  @doc """
  Permanently deletes the project from the store.
  """
  def run(opts) do
    opts.project
    |> Store.new()
    |> Store.delete_project()
  end
end

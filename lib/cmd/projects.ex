defmodule Cmd.Projects do
  def run(_opts) do
    Store.list_projects()
    |> Enum.each(&IO.puts(&1.name))
  end
end

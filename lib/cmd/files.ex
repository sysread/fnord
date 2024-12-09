defmodule Cmd.Files do
  def run(_opts) do
    Store.get_project()
    |> Store.Project.stored_files()
    |> Stream.map(& &1.rel_path)
    |> Enum.sort()
    |> Enum.each(&IO.puts(&1))
  end
end

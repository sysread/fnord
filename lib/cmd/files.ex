defmodule Cmd.Files do
  def run(_opts) do
    Store.new()
    |> Store.list_files()
    |> Enum.each(&IO.puts(&1))
  end
end

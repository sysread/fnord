defmodule Cmd.Files do
  def run(opts) do
    opts.project
    |> Store.new()
    |> Store.list_files()
    |> Enum.each(&IO.puts(&1))
  end
end

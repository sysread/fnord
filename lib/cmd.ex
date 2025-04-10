defmodule Cmd do
  @callback spec() :: Keyword.t()
  @callback run(opts :: map, subcommands :: list, unknown :: map) :: any

  def default_workers, do: 12
end

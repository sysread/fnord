defmodule Cmd do
  @callback spec() :: Keyword.t()
  @callback run(opts :: map) :: any

  def default_workers, do: 8
end

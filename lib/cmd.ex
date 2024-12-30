defmodule Cmd do
  @callback spec() :: Keyword.t()
  @callback run(opts :: map) :: any

  def default_concurrency, do: 8
end

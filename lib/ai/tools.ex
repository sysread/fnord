defmodule AI.Tools do
  @callback spec() :: map
  @callback call(struct, map) :: {:ok, String.t()}
end

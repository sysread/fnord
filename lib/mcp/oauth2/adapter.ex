defmodule MCP.OAuth2.Adapter do
  @moduledoc false

  @callback start_flow(map()) ::
              {:ok, non_neg_integer(), String.t(), String.t(), String.t(), String.t()}
              | {:error, term()}
end

defmodule AI.Agent do
  @type response :: {:ok, String.t()}
  @type error :: {:error, String.t()}

  # -----------------------------------------------------------------------------
  # Behaviour definition
  # -----------------------------------------------------------------------------
  @callback get_response(ai :: AI.t(), opts :: map()) :: response | error
end

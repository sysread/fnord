defmodule AI.Agent do
  @type response :: {:ok, any()}
  @type error :: {:error, String.t()}

  # -----------------------------------------------------------------------------
  # Behaviour definition
  # -----------------------------------------------------------------------------
  @callback get_response(ai :: AI.t(), opts :: map()) :: response | error
end

defmodule AI.Agent do
  @type response :: {:ok, any()}
  @type error :: {:error, String.t()}

  # -----------------------------------------------------------------------------
  # Behaviour definition
  # -----------------------------------------------------------------------------
  @callback get_response(opts :: map()) :: response | error
end

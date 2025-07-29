defmodule AI.Agent do
  @type response :: {:ok, any}
  @type error :: {:error, binary}

  # -----------------------------------------------------------------------------
  # Behaviour definition
  # -----------------------------------------------------------------------------
  @callback get_response(opts :: map()) :: response | error
end

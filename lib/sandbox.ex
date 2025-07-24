defmodule Sandbox do
  @moduledoc """
  Session-sandbox abstraction for safe, concurrent code editing environments.
  """

  @callback prepare_sandbox(session_id :: term(), context :: map()) ::
              {:ok, state :: map()} | {:error, any()}
  @callback sandbox_path(state :: map()) :: Path.t()
  @callback finalize_sandbox_commit(state :: map()) :: :ok | {:error, any()}
  @callback finalize_sandbox_discard(state :: map()) :: :ok | {:error, any()}
  @callback cleanup_sandbox(state :: map()) :: :ok
end

defmodule Sandbox do
  @moduledoc """
  Session-sandbox abstraction for safe, concurrent code editing environments.
  """

  @doc """
  Prepares and initializes a sandbox environment for the given session and context.

  ## Arguments
  - session_id: Unique identifier for the session (for example, the process pid)
  - context: Map with project/environment info required for sandbox setup

  ## Returns
  - {:ok, state}: on success
  - {:error, reason}: on failure
  """
  @callback prepare_sandbox(session_id :: term(), context :: map()) :: {:ok, state :: map()} | {:error, any()}

  @doc """
  Returns the filesystem path where the sandbox environment is located.

  ## Arguments
  - state: Map containing the current sandbox state

  ## Returns
  - Path.t(): the sandbox directory path
  """
  @callback sandbox_path(state :: map()) :: Path.t()

  @doc """
  Finalizes the sandbox by committing the changes made during the session.

  ## Arguments
  - state: Map containing the current sandbox state

  ## Returns
  - :ok: on successful commit
  - {:error, reason}: on failure
  """
  @callback finalize_sandbox_commit(state :: map()) :: :ok | {:error, any()}

  @doc """
  Discards any changes made in the sandbox and finalizes the session.

  ## Arguments
  - state: Map containing the current sandbox state

  ## Returns
  - :ok: on successful discard
  - {:error, reason}: on failure
  """
  @callback finalize_sandbox_discard(state :: map()) :: :ok | {:error, any()}

  @doc """
  Cleans up the sandbox environment, removing any temporary files or directories.

  ## Arguments
  - state: Map containing the current sandbox state

  ## Returns
  - :ok: on successful cleanup
  """
  @callback cleanup_sandbox(state :: map()) :: :ok
end

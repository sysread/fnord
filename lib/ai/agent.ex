defmodule AI.Agent do
  @moduledoc """
  Behavior for AI agents that process instructions and return responses.

  This behavior defines the contract between the coordinator and specialized
  agents, ensuring consistent interfaces and proper error handling across the
  agent system.
  """

  @doc """
  Process instructions and return a response using the agent's specialized
  capabilities.
  """
  @callback get_response(map) :: {:ok, any} | {:error, any}
end

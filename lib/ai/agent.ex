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

  @spec get_response(module, map) :: {:ok, any} | {:error, any}
  def get_response(agent_module, args) do
    if load_agent(agent_module) && is_agent(agent_module) do
      agent_module.get_response(args)
    else
      {:error, "Agent module #{inspect(agent_module)} does not implement get_response/1"}
    end
  end

  defp load_agent(mod), do: Code.ensure_loaded?(mod)
  defp is_agent(mod), do: function_exported?(mod, :get_response, 1)
end

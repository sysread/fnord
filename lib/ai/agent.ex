defmodule AI.Agent do
  @moduledoc """
  Behavior for AI agents that process instructions and return responses.

  This behavior defines the contract between the coordinator and specialized
  agents, ensuring consistent interfaces and proper error handling across the
  agent system.
  """

  # ----------------------------------------------------------------------------
  # Behavior Callbacks
  # ----------------------------------------------------------------------------
  @callback get_response(map) :: {:ok, any} | {:error, any}

  # ----------------------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------------------
  defstruct [
    :name,
    :impl
  ]

  @type t :: %__MODULE__{
          name: nil | binary,
          impl: module
        }

  @doc """
  Create a new agent instance.

  If `:named?` is set to `false`, the agent will not be assigned a name. This
  is intended specifically for `AI.Agent.Nomenclater`, which does the naming on
  behalf of `Services.NamePool`, which can't be used directly by `Nomenclater`
  because that would create a circular dependency.
  """
  @spec new(module, keyword) :: t
  def new(impl, opts \\ []) do
    with :ok <- validate_agent_module(impl),
         {:ok, name} <- get_name(opts) do
      %__MODULE__{
        name: name,
        impl: impl
      }
    else
      {:error, reason} ->
        raise "Failed to create agent: #{inspect(reason)}"
    end
  end

  @doc """
  Delegate to the agent implementation's `get_response/1` function. Includes
  the agent in the args map.
  """
  @spec get_response(t, map) :: {:ok, any} | {:error, any}
  def get_response(agent, args) do
    args
    |> Map.put(:agent, agent)
    |> agent.impl.get_response()
  end

  @doc """
  Delegate to `AI.Completion.get/1` with the agent's name included in the args.
  Intended to be called by implementors of `AI.Agent` when they need to
  generate completions as part of their response processing.
  """
  @spec get_completion(t, keyword) :: {:ok, AI.Completion.t()} | {:error, any}
  def get_completion(agent, args) do
    args
    |> Keyword.put(:name, agent.name)
    |> AI.Completion.get()
  end

  @doc """
  Delegate to `AI.Completion.tools_used/1` to extract the tools used from a
  completion.
  """
  @spec tools_used(AI.Completion.t()) :: %{binary => non_neg_integer()}
  def tools_used(completion) do
    AI.Completion.tools_used(completion)
  end

  # ----------------------------------------------------------------------------
  # Private functions
  # ----------------------------------------------------------------------------
  defp validate_agent_module(mod) do
    cond do
      !Code.ensure_loaded?(mod) -> {:error, :module_not_found}
      !function_exported?(mod, :__info__, 1) -> {:error, :not_a_module}
      true -> :ok
    end
  end

  defp get_name(opts) do
    name = Keyword.get(opts, :name, nil)

    cond do
      !is_nil(name) ->
        Services.NamePool.restore_name(self(), name)
        {:ok, name}

      Keyword.get(opts, :named?, true) ->
        Services.NamePool.checkout_name()

      true ->
        {:ok, Services.NamePool.default_name()}
    end
  end
end

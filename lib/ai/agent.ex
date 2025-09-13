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
    :named?,
    :impl
  ]

  @type t :: %__MODULE__{
          name: nil | binary,
          named?: boolean,
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
    with :ok <- validate_agent_module(impl) do
      %__MODULE__{
        name: Keyword.get(opts, :name, nil),
        named?: Keyword.get(opts, :named?, true),
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

  The agent's name is managed here, checking out a name from
  `Services.NamePool` if the agent is named but doesn't yet have a name, or
  associating the agent's existing name if it does. The name is checked back in
  after the response is generated.

  The call is wrapped in a `Task` to provide a global identifier for logging
  and tracing purposes, which is associated with the agent's name.
  """
  @spec get_response(t, map) :: {:ok, any} | {:error, any}
  def get_response(agent, args) do
    parent_pool = HttpPool.get()

    Task.async(fn ->
      HttpPool.set(parent_pool)

      agent =
        cond do
          agent.named? && is_binary(agent.name) ->
            Services.NamePool.associate_name(agent.name)
            agent

          agent.named? ->
            Services.NamePool.checkout_name()
            |> case do
              {:ok, name} -> %{agent | name: name}
              {:error, _} -> %{agent | name: Services.NamePool.default_name()}
            end

          true ->
            name = Services.NamePool.default_name()
            %{agent | name: name}
        end

      try do
        args
        |> Map.put(:agent, agent)
        |> agent.impl.get_response()
      after
        if agent.named? && is_binary(agent.name) do
          Services.NamePool.checkin_name(agent.name)
        end
      end
    end)
    |> Task.await(:infinity)
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
end

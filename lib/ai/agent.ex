defmodule AI.Agent do
  @moduledoc """
  Behavior for AI agents that process instructions and return responses.

  This behavior defines the contract between the coordinator and specialized agents,
  ensuring consistent interfaces and proper error handling across the agent system.
  """

  @type instructions :: binary()
  @type conversation_id :: non_neg_integer()
  @type agent_response :: binary()
  @type agent_error :: binary()

  @type agent_opts :: %{
          instructions: instructions(),
          conversation: conversation_id()
        }

  @type response :: {:ok, agent_response()}
  @type error :: {:error, agent_error()}

  @doc """
  Process instructions and return a response using the agent's specialized capabilities.

  The agent should:
  1. Parse and validate the instructions
  2. Execute its specialized workflow (research, planning, coding, etc.)
  3. Return a comprehensive response or detailed error information
  4. Maintain conversation context appropriately

  Instructions format should include:
  - Clear objective or milestone description
  - Context from the original user request
  - Any specific constraints or requirements
  """
  @callback get_response(agent_opts()) :: response() | error()

  @doc """
  Validate that the provided options contain required fields and are well-formed.

  This should check:
  - Required fields are present (instructions, conversation)
  - Instructions are non-empty and meaningful
  - Conversation ID is valid
  """
  @callback validate_opts(agent_opts()) :: :ok | {:error, binary()}

  @optional_callbacks validate_opts: 1

  @doc """
  Validate agent options according to the standard contract.

  This is a default implementation that can be used by agents that don't
  need custom validation logic.
  """
  @spec validate_standard_opts(agent_opts()) :: :ok | {:error, binary()}
  def validate_standard_opts(%{instructions: instructions, conversation: conversation_id})
      when is_binary(instructions) and is_integer(conversation_id) do
    cond do
      String.trim(instructions) == "" ->
        {:error, "Instructions cannot be empty"}

      conversation_id < 0 ->
        {:error, "Conversation ID must be non-negative"}

      true ->
        :ok
    end
  end

  def validate_standard_opts(opts) when is_map(opts) do
    cond do
      not Map.has_key?(opts, :instructions) ->
        {:error, "Missing required field: instructions"}

      not Map.has_key?(opts, :conversation) ->
        {:error, "Missing required field: conversation"}

      not is_binary(Map.get(opts, :instructions)) ->
        {:error, "Instructions must be a binary string"}

      not is_integer(Map.get(opts, :conversation)) ->
        {:error, "Conversation ID must be an integer"}

      true ->
        validate_standard_opts(opts)
    end
  end

  def validate_standard_opts(_opts) do
    {:error, "Options must be a map"}
  end
end

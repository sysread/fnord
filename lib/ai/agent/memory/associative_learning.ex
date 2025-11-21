defmodule AI.Agent.Memory.AssociativeLearning do
  @moduledoc """
  Agent that scores memories for a conversation.

  Given a conversation and a list of `AI.Memory` structs, it asks the LLM to
  assign each memory a relevance score from 1–10 and returns a map of
  `memory_id => score` keyed by each memory's `id`.

  Response format:

      {:ok, conversation_id, %{"memory_id_1" => score_1, ...}}

  On transient decode/validation failures, the agent will retry up to
  `@retry_limit` times before returning an error.
  """

  @type conversation_id :: String.t()
  @type memory_score_map :: %{optional(String.t()) => pos_integer()}

  @retry_limit 3
  @associative_high_threshold 9
  @associative_low_threshold 2
  @associative_strengthen_delta 0.2
  @associative_weaken_delta -0.2

  # ----------------------------------------------------------------------------
  # Behaviour implementation
  # ----------------------------------------------------------------------------
  @behaviour AI.Agent
  @model AI.Model.large_context(:balanced)

  @system_prompt """
  You are an associative memory selection and scoring helper inside a larger
  agent system.

  Your job is to read the current conversation and a list of candidate
  memories, then assign each memory a *relevance score* from 1 (barely
  relevant) to 10 (extremely central) **for this specific conversation**.

  Important rules:
  - You MUST return a JSON object where each key is a memory id (string) and
    each value is an integer score from 1 to 10.
  - Every provided memory id MUST appear in the object, even if you think it
    is only weakly relevant.
  - Use the full range 1–10 when appropriate; do not cluster all scores at one
    value.
  - Base your judgment only on the provided conversation messages and memory
    descriptions.
  - If a memory seems unrelated to the conversation, give it a low score like
    1 or 2, but still include it in the result.
  """

  @response_format %{
    type: "json_schema",
    json_schema: %{
      name: "memory_relevance_scores",
      strict: true,
      schema: %{
        type: "object",
        description: """
        Map of memory ids to relevance scores (integer 1–10) for the current
        conversation.
        """,
        required: [],
        additionalProperties: %{
          type: "integer",
          minimum: 1,
          maximum: 10
        },
        properties: %{}
      }
    }
  }

  @doc """
  Entry point required by the `AI.Agent` behaviour.

  Expected args map:

      %{
        agent: %AI.Agent{},
        conversation: %Store.Project.Conversation{} | %{id: id, messages: messages},
        memories: [%AI.Memory{}, ...]
      }

  Returns `{:ok, scores}` on success, where `scores` is a map of memory IDs (as
  strings) to integer scores in the range 1–10.
  """
  @impl AI.Agent
  @spec get_response(map()) :: {:ok, memory_score_map} | {:error, term()}
  def get_response(%{agent: agent, conversation: conversation, memories: memories}) do
    with {:ok, scores} <- do_score_with_retries(agent, conversation, memories, @retry_limit) do
      {:ok, scores}
    end
  end

  def get_response(_), do: {:error, :invalid_arguments}

  # ----------------------------------------------------------------------------
  # Core scoring flow with simple retry
  # ----------------------------------------------------------------------------

  defp do_score_with_retries(_agent, _conversation, _memories, 0) do
    {:error, :max_retries_exceeded}
  end

  defp do_score_with_retries(agent, conversation, memories, attempts_left) do
    case score_once(agent, conversation, memories) do
      {:ok, scores} ->
        {:ok, scores}

      {:error, _reason} ->
        do_score_with_retries(agent, conversation, memories, attempts_left - 1)
    end
  end

  @spec score_once(AI.Agent.t(), any, [AI.Memory.t()]) ::
          {:ok, memory_score_map}
          | {:error, term()}
  defp score_once(agent, conversation, memories) do
    messages = build_messages(conversation, memories)

    case AI.Agent.get_completion(agent,
           model: @model,
           messages: messages,
           response_format: @response_format
         ) do
      {:ok, %AI.Completion{response: response}} ->
        response
        |> decode_scores()
        |> apply_scores(conversation, memories)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ----------------------------------------------------------------------------
  # Prompt construction
  # ----------------------------------------------------------------------------

  defp build_messages(conversation, memories) do
    convo_block = format_conversation(conversation)
    memories_block = format_memories(memories)

    user_content = """
    Here is the current conversation:

    #{convo_block}

    -----

    Here are the candidate memories:

    #{memories_block}

    Return ONLY a JSON object mapping memory ids (as strings) to integer
    relevance scores from 1 to 10.
    """

    [
      AI.Util.system_msg(@system_prompt),
      AI.Util.user_msg(user_content)
    ]
  end

  defp format_conversation(%Store.Project.Conversation{} = convo) do
    {:ok, _ts, messages, _metadata} = Store.Project.Conversation.read(convo)
    format_messages(messages)
  end

  defp format_conversation(%{messages: messages}) when is_list(messages) do
    format_messages(messages)
  end

  defp format_conversation(_), do: "(no conversation messages available)"

  defp format_messages(messages) do
    messages
    |> Enum.with_index(1)
    |> Enum.map(fn {msg, idx} ->
      role = Map.get(msg, :role) || Map.get(msg, "role") || "unknown"
      content = Map.get(msg, :content) || Map.get(msg, "content") || ""
      "[#{idx}] #{role}: #{content}"
    end)
    |> Enum.join("\n")
  end

  defp format_memories(memories) do
    memories
    |> Enum.map(fn %AI.Memory{
                     id: id,
                     label: label,
                     scope: scope,
                     response_template: template
                   } = mem ->
      scope_str = to_string(scope)
      # Fallbacks in case some fields are nil
      label = label || id || "(no label)"
      template = template || "(no response template)"

      pattern_info =
        case Map.get(mem, :pattern_tokens) do
          %{} = tokens when map_size(tokens) > 0 ->
            tokens
            |> Enum.take(5)
            |> Enum.map_join(", ", fn {tok, weight} -> "#{tok}:#{weight}" end)
            |> then(&"pattern_tokens: #{&1}")

          _ ->
            "pattern_tokens: (none)"
        end

      """
      - id: #{id}
        scope: #{scope_str}
        label: #{label}
        template: #{template}
        #{pattern_info}
      """
    end)
    |> Enum.join("\n\n")
  end

  # ----------------------------------------------------------------------------
  # Response handling and validation
  # ----------------------------------------------------------------------------

  @spec decode_scores(String.t()) :: {:ok, memory_score_map} | {:error, term()}
  defp decode_scores(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = scores} -> validate_scores(scores)
      {:ok, _other} -> {:error, :invalid_response_shape}
      {:error, reason} -> {:error, {:decode_error, reason}}
    end
  end

  defp decode_scores(_), do: {:error, :invalid_response}

  @spec validate_scores(map()) :: {:ok, memory_score_map} | {:error, term()}
  defp validate_scores(scores) when is_map(scores) do
    with true <-
           Enum.all?(scores, fn {k, v} ->
             is_binary(k) &&
               is_integer(v) &&
               v >= 1 &&
               v <= 10
           end) do
      {:ok, scores}
    else
      _ -> {:error, :invalid_scores}
    end
  end

  defp apply_scores({:error, reason}, _, _), do: {:error, reason}

  defp apply_scores({:ok, scores}, match_input, memories) do
    memories
    |> Enum.each(fn memory ->
      scores
      |> Map.get(memory.id)
      |> case do
        score when is_integer(score) and score >= @associative_high_threshold ->
          UI.debug("Relearning", "(#{memory.scope}) #{memory.label}")
          updated = AI.Memory.train(memory, match_input, @associative_strengthen_delta)
          Services.Memories.update(updated)

        score when is_integer(score) and score <= @associative_low_threshold ->
          UI.debug("Unlearning", "(#{memory.scope}) #{memory.label}")
          updated = AI.Memory.train(memory, match_input, @associative_weaken_delta)
          Services.Memories.update(updated)

        _ ->
          nil
      end
    end)

    {:ok, scores}
  end
end

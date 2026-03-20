defmodule AI.Agent.Memory.Deduplicator do
  @moduledoc """
  Agent that examines two same-scope long-term memories and decides whether to
  merge them into a single synthesized memory.

  Returns a structured JSON response (no prose) with shape:

    {"merge": false}

  or

    {"merge": true, "title": "...", "content": "...", "topics": [...]}

  The caller is responsible for saving the synthesized memory and deleting both
  originals on a merge decision.
  """

  @behaviour AI.Agent

  @model AI.Model.large_context()

  @prompt """
  You will be given two long-term memories (memory_a and memory_b). Decide
  whether they should be merged into a single memory.

  Return ONLY valid JSON -- no prose, no commentary:

  - {"merge": false}
    if the memories contain distinct information that should remain separate.

  - {"merge": true, "title": "...", "content": "...", "topics": [...]}
    if the memories substantially overlap or are redundant. Write a clean
    synthesis that preserves all unique information from both. Choose a title
    that accurately describes the combined content. Topics must be a flat array
    of lowercase strings.

  Be conservative. Only merge when the overlap is substantial and unambiguous.
  When in doubt, return {"merge": false}.

  Do NOT merge memories that merely share a topic but contain distinct
  information. Do NOT discard information to make a merge fit. If merging
  would require omitting something from either memory, do not merge.
  """

  @impl AI.Agent
  def get_response(opts) do
    with {:ok, agent} <- Map.fetch(opts, :agent),
         {:ok, payload} <- Map.fetch(opts, :payload) do
      messages = [AI.Util.system_msg(@prompt), AI.Util.system_msg(payload)]

      agent
      |> AI.Agent.get_completion(
        model: @model,
        log_msgs: false,
        log_tool_calls: false,
        messages: messages,
        toolbox: %{}
      )
      |> case do
        {:ok, %{response: response}} -> {:ok, response}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Evaluates two same-scope memories and returns a merge decision.

  Returns `{:ok, %{"merge" => false}}` to keep both, or
  `{:ok, %{"merge" => true, "title" => ..., "content" => ..., "topics" => [...]}}`.
  """
  @spec run(Memory.t(), Memory.t()) :: {:ok, map()} | {:error, term()}
  def run(%Memory{} = a, %Memory{} = b) do
    payload =
      SafeJson.encode!(%{
        memory_a: %{title: a.title, content: a.content, topics: a.topics},
        memory_b: %{title: b.title, content: b.content, topics: b.topics}
      })

    with {:ok, response} <- invoke_agent(payload),
         {:ok, decoded} <- SafeJson.decode(response),
         :ok <- validate_response(decoded) do
      {:ok, decoded}
    end
  end

  defp invoke_agent(payload) do
    __MODULE__
    |> AI.Agent.new(named?: false)
    |> AI.Agent.get_response(%{payload: payload})
  end

  defp validate_response(%{"merge" => false}), do: :ok

  defp validate_response(%{"merge" => true, "title" => title, "content" => content, "topics" => topics})
       when is_binary(title) and title != "" and is_binary(content) and content != "" and
              is_list(topics),
       do: :ok

  defp validate_response(_), do: {:error, :invalid_response}
end

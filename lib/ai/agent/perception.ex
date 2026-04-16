defmodule AI.Agent.Perception do
  @moduledoc """
  Extracts a structured perception from the conversation transcript: a holistic
  observation plus simple classification fields (intent, sentiment, entities,
  files, actions). This used to live inside `AI.Agent.Intuition` as a plain
  free-text synopsis; separating it lets other subsystems (e.g. samskara
  firing) key off the same perception without re-running it.
  """

  @behaviour AI.Agent

  @model AI.Model.fast()

  @prompt """
  You are an AI agent in a larger system of AI agents that form an aggregate
  mind that responds to the user. You are the Subconsciousness. Your task is to
  read a transcript of a conversation between the user and the Coordinating
  Agent (the "conscious" agent that interacts directly with the user) to
  provide an objective *perception* of the situation for the subconscious to
  react to.

  Identify significant aspects of the situation to react to:
  - Broad context or goals
  - Active concerns or questions
  - The user's motives or reactions
  - The user's emotional state or tone
  - What is being requested of you
  - The length of the conversation (implying the user may be correcting your missteps)
  - The topics and decision-making context that lead to the most recent user prompt (if any)

  Classify the user's prompt into one of these categories:
  - **interface**: the user is asking about fnord itself - its CLI, commands, flags, configuration, features, or behavior
  - **codebase**: the user is asking about the project code, architecture, bugs, or implementation
  - **correction**: the user is correcting a previous response or pointing out a mistake
  - **continuation**: the user is continuing or refining an ongoing task
  - **meta**: the user is asking about the agent's capabilities, process, or reasoning
  - **ambiguous**: the prompt could reasonably be about fnord's interface or the project codebase

  Interpret the situation holistically, but be realistic and do not overreach.
  You are the *objective observer* of the situation.
  The subconsciousness relies on you to provide a clear and accurate perception of the situation.
  Do your best to focus on the reality of the situation, without applying judgement or interpretation.
  You are the *φαντασία*, not the *ὑπόληψις*.

  You are NOT responding to the user.
  Your output will be presented to the various subconscious drives to generate instinctive reactions.

  Respond using the following format exactly, keeping each section short:

  Classification: <category>
  Intent: <question|request|critique|clarification|conversation>
  Sentiment: <positive|neutral|negative|frustrated|excited>
  Entities: <comma-separated list of named entities mentioned in the last turn, or "none">
  Files: <comma-separated list of file paths mentioned in the last turn, or "none">
  Actions: <comma-separated list of action verbs the user wants performed, or "none">
  Observation: <one short paragraph, first-person, presenting a holistic interpretation of events>
  """

  defmodule Result do
    @moduledoc """
    Structured perception of the current turn, as parsed from the Perception
    agent's response. Produced by `AI.Agent.Perception.get_response/1` and
    consumed by `AI.Agent.Intuition` and `AI.Samskara.Firing`.
    """
    defstruct [
      :observation,
      :classification,
      :intent,
      :sentiment,
      :entities,
      :files,
      :actions,
      :raw
    ]

    @type t :: %__MODULE__{
            observation: binary,
            classification: atom,
            intent: atom,
            sentiment: atom,
            entities: [binary],
            files: [binary],
            actions: [binary],
            raw: binary
          }

    @spec embed_text(t) :: binary
    def embed_text(%__MODULE__{} = r) do
      [
        r.observation,
        Enum.join(r.entities, " "),
        Enum.join(r.actions, " "),
        Enum.join(r.files, " ")
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")
    end
  end

  # ----------------------------------------------------------------------------
  # AI.Agent behaviour
  # ----------------------------------------------------------------------------
  @impl AI.Agent
  def get_response(opts) do
    with {:ok, msgs} <- fetch_msgs(opts) do
      transcript = build_transcript(msgs)

      AI.Accumulator.get_response(
        model: @model,
        prompt: @prompt,
        input: transcript,
        question: "Respond with your subconscious perception in the specified format."
      )
      |> case do
        {:ok, %{response: response}} ->
          log_perception(response)
          {:ok, parse(response)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ----------------------------------------------------------------------------
  # Parsing
  # ----------------------------------------------------------------------------
  @spec parse(binary) :: Result.t()
  def parse(raw) when is_binary(raw) do
    lines = String.split(raw, ~r/\r?\n/, trim: false)

    fields =
      Enum.reduce(lines, %{}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          [key, value] ->
            k = key |> String.trim() |> String.downcase()
            v = String.trim(value)

            if k in ~w[classification intent sentiment entities files actions observation] do
              Map.put(acc, k, v)
            else
              acc
            end

          _ ->
            acc
        end
      end)

    %Result{
      observation: Map.get(fields, "observation") || extract_observation(raw),
      classification: atomize(Map.get(fields, "classification", "ambiguous")),
      intent: atomize(Map.get(fields, "intent", "conversation")),
      sentiment: atomize(Map.get(fields, "sentiment", "neutral")),
      entities: split_list(Map.get(fields, "entities")),
      files: split_list(Map.get(fields, "files")),
      actions: split_list(Map.get(fields, "actions")),
      raw: raw
    }
  end

  defp extract_observation(raw) do
    # If the model didn't honor the Observation: header, fall back to the
    # whole response minus any leading "Classification:" preamble.
    case String.split(raw, "Observation:", parts: 2) do
      [_, obs] -> String.trim(obs)
      [single] -> String.trim(single)
    end
  end

  defp atomize(nil), do: :unknown

  defp atomize(value) when is_binary(value) do
    v =
      value
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/\s+/, "_")

    if v == "" do
      :unknown
    else
      try do
        String.to_existing_atom(v)
      rescue
        ArgumentError -> String.to_atom(v)
      end
    end
  end

  defp atomize(value) when is_atom(value), do: value
  defp atomize(_), do: :unknown

  defp split_list(nil), do: []
  defp split_list(""), do: []

  defp split_list(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "none" ->
        []

      _ ->
        value
        |> String.split(~r/[,]/)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------
  defp fetch_msgs(opts) do
    case Map.fetch(opts, :msgs) do
      {:ok, msgs} when is_list(msgs) -> {:ok, msgs}
      _ -> {:error, "Missing required argument: msgs"}
    end
  end

  defp build_transcript(msgs) do
    msgs
    |> Enum.filter(fn
      %{role: "user"} -> true
      %{role: "assistant", content: c} when is_binary(c) -> true
      _ -> false
    end)
    |> Enum.map(fn %{role: role, content: content} ->
      "#{role} said: #{content}"
    end)
    |> Enum.join("\n\n")
  end

  defp log_perception(response) do
    UI.report_step("Perception", UI.italicize(response))
  end
end

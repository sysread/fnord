defmodule AI.Agent.ReactionClassifier do
  @moduledoc """
  Lightweight, single-pass classifier run on the hot path of every user turn.
  Given the previous assistant response and the current user message, decides
  whether the exchange warrants minting a samskara and, if so, tags a reaction
  label and a rough intensity (0.0-1.0).

  Returns `{:ok, :skip}` or `{:ok, {:mint, label, intensity}}`.
  """

  @behaviour AI.Agent

  @model AI.Model.fast()

  @prompt """
  You are a lightweight classifier. Given the assistant's previous response and
  the user's next message, decide whether the user's message represents a
  meaningful reaction to the assistant's work that should be remembered.

  Respond with EXACTLY one of the following, nothing else:

  SKIP
  MINT <label> <intensity>

  Where:
  - <label> is one of: correction, approval, pivot, frustration, delight, clarification, other
  - <intensity> is a decimal in [0.0, 1.0]; use >= 0.5 only when the reaction is clear and strong.

  Default to SKIP unless the user's message clearly reacts to the assistant's
  work. Small-talk, new unrelated questions, or neutral continuations are SKIP.
  """

  @type classification :: :skip | {:mint, atom, float}

  @impl AI.Agent
  def get_response(opts) do
    with {:ok, prev} <- fetch(opts, :prev_assistant),
         {:ok, curr} <- fetch(opts, :user_message) do
      agent = Map.get(opts, :agent)

      messages = [
        AI.Util.system_msg(@prompt),
        AI.Util.user_msg("""
        # Previous assistant response
        #{prev}

        # Current user message
        #{curr}
        """)
      ]

      AI.Agent.get_completion(agent,
        model: @model,
        messages: messages
      )
      |> case do
        {:ok, %{response: response}} ->
          parsed = parse(response)
          log(response, parsed)
          {:ok, parsed}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec parse(binary) :: classification
  def parse(response) when is_binary(response) do
    response
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
    |> case do
      ["SKIP" | _] ->
        :skip

      ["MINT", label, intensity | _] ->
        {:mint, normalize_label(label), normalize_intensity(intensity)}

      _ ->
        :skip
    end
  end

  defp normalize_label(label) do
    label
    |> String.downcase()
    |> case do
      v when v in ~w[correction approval pivot frustration delight clarification other] ->
        String.to_atom(v)

      _ ->
        :other
    end
  end

  defp normalize_intensity(value) when is_binary(value) do
    case Float.parse(value) do
      {f, _} -> clamp(f, 0.0, 1.0)
      :error -> 0.5
    end
  end

  defp clamp(v, lo, _hi) when v < lo, do: lo
  defp clamp(v, _lo, hi) when v > hi, do: hi
  defp clamp(v, _lo, _hi), do: v

  defp fetch(opts, key) do
    case Map.fetch(opts, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> {:error, "Missing required argument: #{key}"}
    end
  end

  defp log(raw, parsed) do
    if Util.Env.looks_truthy?("FNORD_DEBUG_SAMSKARA") do
      UI.debug("samskara:classifier", "#{inspect(parsed)} <= #{inspect(raw)}")
    end
  end
end

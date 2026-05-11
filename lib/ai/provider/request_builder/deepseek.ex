defmodule AI.Provider.RequestBuilder.DeepSeek do
  @moduledoc """
  DeepSeek implementation of the `AI.Provider.RequestBuilder` behaviour.

  DeepSeek is OpenAI-API-compatible at the chat-completions surface:
  `model`, `messages`, `tools`, `response_format`, `reasoning_effort`
  (for reasoning models). No `verbosity` knob, no `web_search_options`.

  ## API key resolution

  Reads `FNORD_DEEPSEEK_API_KEY` first, falling back to
  `DEEPSEEK_API_KEY`. Same fnord-prefix-wins pattern the other
  providers use.

  ## System role

  DeepSeek's chat-completions API follows the legacy `system` role
  convention.
  """

  @behaviour AI.Provider.RequestBuilder

  @impl AI.Provider.RequestBuilder
  def api_key!() do
    ["FNORD_DEEPSEEK_API_KEY", "DEEPSEEK_API_KEY"]
    |> Enum.find_value(fn k -> Util.Env.get_env(k, nil) end)
    |> case do
      nil ->
        raise "Either FNORD_DEEPSEEK_API_KEY or DEEPSEEK_API_KEY environment variable must be set"

      api_key ->
        api_key
    end
  end

  @impl AI.Provider.RequestBuilder
  def system_role(), do: "system"

  @impl AI.Provider.RequestBuilder
  def build_headers(api_key) when is_binary(api_key) do
    [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]
  end

  @impl AI.Provider.RequestBuilder
  def build_payload(model, msgs, tools, response_format, web_search?, _verbosity) do
    # DeepSeek has no web-search-capable model in fnord's catalog. A
    # caller asking for web search here is a programming error; raise
    # at the call site rather than letting the API produce a confusing
    # 4xx (or worse, silently succeed without searching).
    if web_search? and not Map.get(model, :supports_web_search, false) do
      raise ArgumentError,
            "web_search? requested but model #{inspect(model.model)} does not " <>
              "support web search on DeepSeek. DeepSeek has no web-search-" <>
              "capable model today; route web search to a different provider."
    end

    # DeepSeek's chat-completions API supports a narrower response_format
    # set than OpenAI: `{"type": "json_object"}` is accepted, but
    # `{"type": "json_schema", ...}` returns
    # `"This response_format type is unavailable now"`. Degrade
    # json_schema callers to json_object and inject a developer
    # message with the schema text - same Venice-style workaround.
    {wire_response_format, instruction} = adapt_response_format(response_format)

    msgs =
      case instruction do
        nil -> msgs
        text -> msgs ++ [AI.Util.system_msg(text)]
      end

    %{
      model: model.model,
      messages: msgs
    }
    |> Map.merge(
      case wire_response_format do
        nil -> %{}
        rf -> %{response_format: rf}
      end
    )
    |> Map.merge(
      case tools do
        nil -> %{}
        tools -> %{tools: tools}
      end
    )
    |> Map.merge(thinking_field(model))
  end

  # DeepSeek's reasoning dial is two settings, not a sliding scale:
  #
  # - Top-level `thinking` is an object with a `type` field; the only
  #   documented values are `"enabled"` (default) and `"disabled"`.
  #   Wire shape: `%{thinking: %{type: "disabled"}}`.
  # - `reasoning_effort: "low" | "medium" | "high"` is a hint for the
  #   thinking budget when thinking is enabled, but the user-observed
  #   upstream mapping is coarse (low/medium -> high, high -> xhigh)
  #   so the field is effectively a "more vs. most" toggle.
  #
  # fnord's profile reasoning levels map to DeepSeek as:
  # - `:none` -> emit `%{thinking: %{type: "disabled"}}`. Skips
  #   thinking entirely; pairs with profiles configured at `:none`.
  # - `:low` / `:medium` / `:high` -> emit `reasoning_effort` per
  #   level. Thinking is on (default); DeepSeek does its own internal
  #   remapping of the level.
  # - anything else -> emit neither, letting DeepSeek's default apply.
  #
  # `supports_reasoning: false` also forces thinking off; the
  # capability flag is authoritative.
  @spec thinking_field(AI.Model.t()) :: map
  defp thinking_field(%{supports_reasoning: false}), do: %{thinking: %{type: "disabled"}}
  defp thinking_field(%{reasoning: :none}), do: %{thinking: %{type: "disabled"}}
  defp thinking_field(%{reasoning: :low}), do: %{reasoning_effort: "low"}
  defp thinking_field(%{reasoning: :medium}), do: %{reasoning_effort: "medium"}
  defp thinking_field(%{reasoning: :high}), do: %{reasoning_effort: "high"}
  defp thinking_field(_), do: %{}

  # Translate the caller's response_format into:
  #   - the value to send on the wire (or `nil` to omit the field
  #     entirely)
  #   - an optional developer-message instruction restating the
  #     contract in prose
  #
  # DeepSeek accepts only `text` and `json_object`. `json_schema` is
  # rejected with a 400 ("This response_format type is unavailable
  # now"), so we degrade it to `json_object` on the wire and rely on
  # the prompt instruction to convey the actual schema. `nil` caller
  # -> omit response_format entirely (DeepSeek defaults to text).
  @spec adapt_response_format(map | nil) :: {map | nil, binary | nil}
  defp adapt_response_format(nil), do: {nil, nil}

  defp adapt_response_format(%{type: "text"} = rf), do: {rf, nil}

  defp adapt_response_format(%{type: "json_object"} = rf) do
    {rf, json_object_instruction()}
  end

  defp adapt_response_format(%{type: "json_schema", json_schema: js}) when is_map(js) do
    # Degrade to json_object on the wire (DeepSeek doesn't accept
    # json_schema). Inject the schema as a developer instruction.
    schema = Map.get(js, :schema) || Map.get(js, "schema")
    name = Map.get(js, :name) || Map.get(js, "name")
    {%{type: "json_object"}, json_schema_instruction(schema, name)}
  end

  defp adapt_response_format(other), do: {other, nil}

  defp json_object_instruction do
    """
    Your response MUST be a single valid JSON value. Do not include any text outside the JSON.
    """
  end

  defp json_schema_instruction(schema, name) do
    name_line =
      case name do
        nil -> ""
        n -> "Schema name: #{n}\n\n"
      end

    """
    Your response MUST be a single JSON value that VALIDATES against the schema below.
    The schema describes the SHAPE of your output - it is NOT a template to copy.
    Return only the data instance. Do not echo the schema. No prose, no commentary.

    #{name_line}```json
    #{Jason.encode!(schema, pretty: true)}
    ```
    """
  end
end

defmodule AI.Provider.RequestBuilder.Venice do
  @moduledoc """
  Venice implementation of the `AI.Provider.RequestBuilder` behaviour.

  Owns the Venice-shaped wire format for chat-completion requests:

  - Bearer auth header with the API key
  - Top-level `reasoning_effort` field (gated on `model.supports_reasoning`)
  - `venice_parameters` object for web search and reasoning extras
    (gated on capability flags and caller intent)
  - `response_format` defaulting to `%{type: "text"}`

  ## API key resolution

  Reads `FNORD_VENICE_API_KEY` first, falling back to `VENICE_API_KEY`.
  Same prefix-override pattern as OpenAI, so users can pin a different
  key per fnord invocation without disturbing other tools that read the
  canonical upstream env var.

  ## How web search is encoded

  Unlike OpenAI - which uses a top-level `web_search_options` and a
  dedicated search-preview model - Venice handles web search on any
  model via the nested `venice_parameters` object:

      venice_parameters: %{
        enable_web_search: "on",
        enable_web_citations: true,
        strip_thinking_response: true
      }

  - `enable_web_search: "on"` forces a search; `"auto"` lets the model
    decide; `"off"` disables it. We use `"on"` because the only path
    here is the explicit `web_search?: true` request - if the caller
    asked, do it.
  - `enable_web_citations: true` asks the model to inline `^N^`
    superscript markers that reference entries in the
    `web_search_citations` array on the response. The response parser
    consumes those.
  - `strip_thinking_response: true` removes `<think></think>` blocks
    from reasoning models. Without this, the user-visible message would
    include the model's chain-of-thought as plaintext.

  ## What is deliberately not sent

  - `verbosity` is dropped on Venice. Venice expresses verbosity as
    `text: {verbosity: ...}`, not as a top-level field. Rather than
    remap, we drop entirely - verbosity is a known no-op on the main
    Coordinator path today (see engram memory "Verbosity plumbing"),
    so emitting it would be pretending to honor a setting that fnord
    does not currently respect end-to-end. Once verbosity plumbing
    lands, the remap is a two-line addition here.
  - `additionalProperties: false` is strict at Venice's request level;
    the builder is careful not to emit any Venice-unrecognized fields.
  """

  @behaviour AI.Provider.RequestBuilder

  @impl AI.Provider.RequestBuilder
  def api_key!() do
    # Same fnord-prefix-takes-precedence convention as OpenAI.
    ["FNORD_VENICE_API_KEY", "VENICE_API_KEY"]
    |> Enum.find_value(fn k -> Util.Env.get_env(k, nil) end)
    |> case do
      nil ->
        raise "Either FNORD_VENICE_API_KEY or VENICE_API_KEY environment variable must be set"

      api_key ->
        api_key
    end
  end

  @impl AI.Provider.RequestBuilder
  # Venice mirrors OpenAI's chat-completions wire shape but follows the
  # legacy `system` role convention rather than OpenAI's newer
  # `developer`. Sending `developer`-role messages causes Venice to
  # silently treat them as a no-op (or downgrade them in ways that
  # erase any schema instructions / step prompts attached to them),
  # which manifests as the model ignoring our orchestration messages
  # entirely.
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
    # Capability gate: caller asked for web search but the chosen model
    # cannot perform it. Same fail-fast contract as the OpenAI builder -
    # surface the bug at the call site rather than letting Venice produce
    # a confusing 4xx.
    if web_search? and not Map.get(model, :supports_web_search, false) do
      raise ArgumentError,
            "web_search? requested but model #{inspect(model.model)} does not " <>
              "support web search. Use AI.Model.web_search() or another " <>
              "web-search-capable profile."
    end

    # The wire payload always carries an explicit `response_format`
    # (Venice/OpenAI default to text when the field is absent). The
    # caller-supplied value is what drives the developer-message
    # instruction below; defaulting it to `%{type: "text"}` only
    # affects the wire field.
    instruction = response_format_instruction(response_format)
    response_format = response_format || %{type: "text"}

    # Venice does not honor `response_format` as strictly as OpenAI does
    # for json_schema / json_object output. A developer message
    # restating the contract gets the model to comply. The instruction
    # avoids dumping the OpenAI envelope (`{"type": "json_schema",
    # "json_schema": {...}}`) - smaller models read that as "echo this
    # JSON literal" rather than "produce data conforming to this
    # schema" and reply with the schema definition itself.
    msgs =
      case instruction do
        nil -> msgs
        text -> msgs ++ [AI.Util.system_msg(text)]
      end

    %{
      model: model.model,
      messages: msgs,
      response_format: response_format,
      venice_parameters: venice_parameters_for(web_search?)
    }
    |> Map.merge(
      case tools do
        nil -> %{}
        tools -> %{tools: tools}
      end
    )
    |> Map.merge(reasoning_effort_field(model))
  end

  # ---------------------------------------------------------------------------
  # Developer-message instruction text for the caller-supplied
  # response_format. Returns nil when no instruction is needed (caller
  # passed nil, or asked for plain text).
  #
  # The instruction unwraps the OpenAI `response_format` envelope and
  # passes only the inner schema (or just a "respond as JSON" line for
  # `json_object`). Dumping the full envelope - i.e. the literal
  # `{"type": "json_schema", "json_schema": {...}}` - was observed to
  # confuse smaller Venice models into echoing the envelope itself
  # back as the response, which then fails downstream parsers (e.g.
  # `AI.Agent.Review.Decomposer.on_step_complete/2`) that expect a data
  # instance.
  # ---------------------------------------------------------------------------
  @spec response_format_instruction(map | nil) :: binary | nil
  defp response_format_instruction(nil), do: nil

  defp response_format_instruction(%{type: "json_schema", json_schema: js})
       when is_map(js) do
    schema = Map.get(js, :schema) || Map.get(js, "schema")
    name = Map.get(js, :name) || Map.get(js, "name")

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

  defp response_format_instruction(%{type: "json_object"}) do
    """
    Your response MUST be a single valid JSON value. Do not include any text outside the JSON.
    """
  end

  defp response_format_instruction(_), do: nil

  # ---------------------------------------------------------------------------
  # reasoning_effort emission.
  #
  # Same two gates as the OpenAI builder, but Venice accepts a wider set
  # of effort levels. We pass through the OpenAI-shared values verbatim;
  # Venice-only levels (`:xhigh`, `:max`) are deliberately not part of
  # the global type to avoid forcing OpenAI to define a mapping. If a
  # caller has explicitly chosen one of those by writing the atom into
  # `model.reasoning`, we still honor it here.
  # ---------------------------------------------------------------------------
  @spec reasoning_effort_field(AI.Model.t()) :: map
  defp reasoning_effort_field(%{supports_reasoning: false}), do: %{}

  defp reasoning_effort_field(%{reasoning: level}) do
    case level do
      :none -> %{reasoning_effort: "none"}
      :minimal -> %{reasoning_effort: "minimal"}
      :low -> %{reasoning_effort: "low"}
      :medium -> %{reasoning_effort: "medium"}
      :high -> %{reasoning_effort: "high"}
      # Venice-only extras. Accepted by Venice's API but not part of the
      # global enum - if a caller explicitly writes them in via
      # `AI.Model.with_reasoning(model, :xhigh)`, we honor it.
      :xhigh -> %{reasoning_effort: "xhigh"}
      :max -> %{reasoning_effort: "max"}
      _ -> %{}
    end
  end

  # ---------------------------------------------------------------------------
  # venice_parameters object construction.
  #
  # `strip_thinking_response: true` is set on every Venice request,
  # regardless of web search. Many Venice models (including the ones
  # fnord configures) emit `<think>...</think>` blocks as part of their
  # reasoning even when `reasoning_effort` is not requested. Without
  # stripping, those blocks leak into the assistant message body and
  # break downstream JSON parsing in agents that expect structured
  # output (deduplicator, indexer, nomenclater). The field name is
  # specifically about removing the thinking output from the visible
  # message, not disabling reasoning - the model still reasons
  # internally.
  #
  # When `web_search?: true`, we additionally turn on web search and
  # citation markers. Other venice_parameters fields (`character_slug`,
  # `enable_e2ee`, etc.) are left at their defaults; surface them only
  # when fnord has a use for them.
  # ---------------------------------------------------------------------------
  @spec venice_parameters_for(boolean) :: map
  defp venice_parameters_for(false) do
    %{strip_thinking_response: true}
  end

  defp venice_parameters_for(true) do
    %{
      strip_thinking_response: true,
      enable_web_search: "on",
      enable_web_citations: true
    }
  end
end

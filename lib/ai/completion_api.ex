defmodule AI.CompletionAPI do
  @behaviour AI.Endpoint
  # OpenAI-specific base URL is defined in AI.Endpoint.OpenAI.

  @type model :: AI.Model.t()
  @type msgs :: [map()]
  @type tools :: nil | [AI.Tools.tool_spec()]
  @type response_format :: nil | map
  @type web_search? :: boolean
  @type verbosity :: nil | String.t()

  @type usage :: non_neg_integer
  @type msg_response :: {:ok, :msg, binary, usage}
  @type tool_response :: {:ok, :tool, list(map)}

  @type response ::
          msg_response
          | tool_response
          | {:error, map}
          | {:error, binary}
          | {:error, :api_unavailable, any}
          | {:error, :context_length_exceeded, non_neg_integer}

  # The model-call boundary: everything below this contract is wire concerns
  # (payload shape, auth, transport, retry); everything above it is the
  # completion loop. `AI.Completion` calls through `impl/0` so tests can
  # substitute canned model responses per process tree without touching the
  # network stack.
  @callback get(model, msgs, tools, response_format, web_search?, verbosity) :: response

  @behaviour AI.CompletionAPI

  @doc """
  Returns the current completion API module. Overridden per process tree via
  the `:completion_api` config key for unit testing. See `Fnord.TestCase`.
  """
  @spec impl() :: module()
  def impl() do
    Services.Globals.get_env(:fnord, :completion_api) || __MODULE__
  end

  @impl AI.Endpoint
  def endpoint_path, do: AI.Endpoint.OpenAI.endpoint_path()

  @doc """
  Provider-specific error classifier is delegated to AI.Endpoint.OpenAI.
  """
  @impl AI.Endpoint
  def endpoint_error_classify(status, body, headers, transport_reason) do
    AI.Endpoint.OpenAI.endpoint_error_classify(status, body, headers, transport_reason)
  end

  def _legacy_classifier_case_tuple(status, body, transport_reason) do
    {status, body, transport_reason}
  end

  # Legacy classifier body removed; kept stubs above for dialyzer stability.
  # ----------------------------------------------------------------------
  # """
  # @impl AI.Endpoint
  # def endpoint_error_classify(status, body, _headers, transport_reason) do
  #   ...
  # end
  # """

  @impl AI.CompletionAPI
  def get(
        model,
        msgs,
        tools \\ nil,
        response_format \\ nil,
        web_search? \\ false,
        verbosity \\ nil
      ) do
    api_key = get_api_key!()

    response_format =
      if is_nil(response_format) do
        %{type: "text"}
      else
        response_format
      end

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    payload = build_payload(model, msgs, tools, response_format, web_search?, verbosity)

    result =
      try do
        AI.Endpoint.post_json(__MODULE__, headers, payload)
        |> case do
          {:transport_error, error} ->
            get_error(error)

          {:http_error, error} ->
            case get_error(error) do
              {:error, :context_length_exceeded, _usage} = err ->
                err

              {:error, %{message: msg}} ->
                UI.error("HTTP error while calling OpenAI API: #{msg}")
                {:error, %{message: msg}}

              other ->
                other
            end

          {:ok, %{body: response} = _payload} ->
            get_response(response)
        end
      rescue
        e in RuntimeError ->
          {:error,
           %{
             http_status: 500,
             error: """
             Runtime error: #{Exception.message(e)}
             #{Exception.format_stacktrace(__STACKTRACE__)}
             """
           }}

        e in ArgumentError ->
          {:error,
           %{
             http_status: 500,
             error: """
             Argument error: #{Exception.message(e)}
             #{Exception.format_stacktrace(__STACKTRACE__)}
             """
           }}

        e ->
          {:error,
           %{
             http_status: 500,
             error: """
             Unexpected error: #{Exception.message(e)}
             #{Exception.format_stacktrace(__STACKTRACE__)}
             """
           }}
      end

    result
  end

  # -----------------------------------------------------------------------------
  # Private functions
  # -----------------------------------------------------------------------------
  @spec get_api_key!() :: binary
  defp get_api_key!() do
    ["FNORD_OPENAI_API_KEY", "OPENAI_API_KEY"]
    |> Enum.find_value(fn k -> Util.Env.get_env(k, nil) end)
    |> case do
      nil ->
        raise "Either FNORD_OPENAI_API_KEY or OPENAI_API_KEY environment variable must be set"

      api_key ->
        api_key
    end
  end

  # --------------------------------------------------------------------------
  # Responses API request payload
  #
  # Wire shape (https://platform.openai.com/docs/api-reference/responses/create):
  #
  #   %{
  #     model: ...,
  #     input: [<typed items>...],     # NOT "messages"
  #     text: %{format: ..., verbosity: ...},
  #     tools: [...],                  # web_search lives here as a tool entry
  #     reasoning: %{effort: ...},
  #     store: false                   # fnord manages conversation state locally
  #   }
  #
  # Internal callers still pass chat-completions-shaped raw maps for messages
  # and chat-completions-shaped tool calls. `to_input/1` translates on the
  # way out; `get_response/1` translates on the way back. Phase 2b removes
  # the translation by flipping the internal canonical format to AI.Message
  # structs (which are already Responses-shaped).
  # --------------------------------------------------------------------------

  defp build_payload(model, msgs, tools, response_format, web_search?, verbosity) do
    text_field =
      %{format: normalize_response_format(response_format)}
      |> maybe_put(:verbosity, verbosity)

    %{
      model: model.model,
      input: to_input(msgs),
      text: text_field,
      store: false
    }
    |> maybe_put(:tools, build_tools(tools, web_search?))
    |> maybe_put(:reasoning, reasoning_param(model))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # text.format under the Responses API hoists json_schema's inner fields
  # (name, schema, description, strict) to the format object itself. Chat
  # Completions nested them inside a `json_schema` map. Internal agents and
  # user-supplied skill response_formats still use the nested shape; we flatten
  # here so the boundary owns the wire-format quirk, not every caller.
  #
  # Already-flat shapes ({type: "json_schema", name:, schema:, ...}) and
  # non-schema formats ({type: "text"}, {type: "json_object"}) pass through.
  defp normalize_response_format(%{type: "json_schema"} = fmt) do
    cond do
      Map.has_key?(fmt, :json_schema) -> hoist_json_schema(fmt, :json_schema)
      Map.has_key?(fmt, "json_schema") -> hoist_json_schema(fmt, "json_schema")
      true -> fmt
    end
  end

  defp normalize_response_format(%{"type" => "json_schema"} = fmt) do
    cond do
      Map.has_key?(fmt, :json_schema) -> hoist_json_schema(fmt, :json_schema)
      Map.has_key?(fmt, "json_schema") -> hoist_json_schema(fmt, "json_schema")
      true -> fmt
    end
  end

  defp normalize_response_format(fmt), do: fmt

  defp hoist_json_schema(fmt, key) do
    {inner, outer} = Map.pop(fmt, key)

    case inner do
      inner when is_map(inner) -> Map.merge(outer, inner)
      _ -> fmt
    end
  end

  # web_search is the current canonical tool name under /v1/responses.
  # web_search_preview is the legacy form kept around for backwards
  # compatibility; new integrations should use web_search.
  defp build_tools(nil, false), do: nil
  defp build_tools(nil, true), do: [%{type: "web_search"}]
  defp build_tools(tools, false), do: tools
  defp build_tools(tools, true), do: tools ++ [%{type: "web_search"}]

  defp reasoning_param(%{reasoning: :low}), do: %{effort: "low"}
  defp reasoning_param(%{reasoning: :medium}), do: %{effort: "medium"}
  defp reasoning_param(%{reasoning: :high}), do: %{effort: "high"}
  defp reasoning_param(_), do: nil

  # Translate messages to Responses input items.
  #
  # Two shape families show up here:
  #
  # 1. **AI.Message structs** (the canonical in-memory shape since Phase
  #    1a / commit 601ad059). Each struct's to_map/1 already produces a
  #    Responses-API-shaped item - INCLUDING the standalone
  #    %{type: "function_call", call_id, name, arguments} shape from
  #    AI.Message.FunctionCall. These take the struct branch below and
  #    pass through unchanged.
  #
  # 2. **Raw chat-completions-shaped maps**: %{role:, content:, tool_calls:}.
  #    These come from test fixtures and a few legacy code paths that
  #    construct messages by hand without going through AI.Util. The
  #    raw-map branch translates the chat-completions shape into
  #    Responses-API items: assistant messages carrying tool_calls fan
  #    out into one function_call item per call.
  #
  # No code path in production produces a raw %{type: "function_call"}
  # map - that shape only exists as output of AI.Message.to_map/1, which
  # always takes the struct branch. So the raw-map branch deliberately
  # does NOT inspect `type` - role-based dispatch is sufficient.
  defp to_input(msgs) when is_list(msgs) do
    Enum.flat_map(msgs, &msg_to_items/1)
  end

  defp msg_to_items(%mod{} = msg)
       when mod in [
              AI.Message.User,
              AI.Message.Assistant,
              AI.Message.System,
              AI.Message.FunctionCall,
              AI.Message.FunctionCallOutput,
              AI.Message.Reasoning
            ] do
    [AI.Message.to_map(msg)]
  end

  defp msg_to_items(msg) when is_map(msg) do
    role = field(msg, :role)
    content = field(msg, :content)
    tool_calls = field(msg, :tool_calls)
    tool_call_id = field(msg, :tool_call_id)

    cond do
      role == "tool" ->
        [%{type: "function_call_output", call_id: tool_call_id, output: content || ""}]

      role == "assistant" and is_list(tool_calls) ->
        Enum.map(tool_calls, &tool_call_to_item/1)

      role == "assistant" ->
        [
          %{
            type: "message",
            role: "assistant",
            content: [%{type: "output_text", text: content || ""}]
          }
        ]

      role in ["user", "developer", "system"] ->
        [
          %{
            type: "message",
            role: role,
            content: [%{type: "input_text", text: content || ""}]
          }
        ]

      true ->
        # Unknown role on a raw map. Drop silently rather than fail loudly:
        # the only realistic source is a test fixture or unhydrated legacy
        # data, and there's no useful translation we could synthesize. If a
        # production code path ever lands here we'd see prompt loss in
        # downstream logs, not a silent success.
        []
    end
  end

  defp tool_call_to_item(tc) do
    id = field(tc, :id)
    function = field(tc, :function) || %{}
    name = field(function, :name)
    args = field(function, :arguments)

    %{type: "function_call", call_id: id, name: name, arguments: args || "{}"}
  end

  # Read a field from a map tolerating atom OR string keys without ever
  # atomizing a raw input key.
  defp field(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  # --------------------------------------------------------------------------
  # Responses API response parsing
  #
  # Wire shape:
  #
  #   %{"output" => [
  #       %{"type" => "message", "content" => [%{"type" => "output_text", "text" => ...}]},
  #       %{"type" => "function_call", "call_id" => ..., "name" => ..., "arguments" => "..."},
  #       %{"type" => "reasoning", ...},
  #       ...
  #     ],
  #     "usage" => %{"total_tokens" => n, ...}}
  #
  # If any function_call items are present, return {:ok, :tool, [calls]} with
  # each call shaped as chat-completions-style %{id, function: %{name, arguments}}
  # for internal callers. Otherwise, concatenate output_text parts from all
  # message items and return {:ok, :msg, text, total_tokens}. Reasoning items
  # are silently dropped in Phase 2a; Phase 2b's AI.Message.Reasoning round-trips
  # them.
  # --------------------------------------------------------------------------

  defp get_response(%{"output" => items, "usage" => usage}) when is_list(items) do
    total_tokens = Map.get(usage, "total_tokens", 0)

    tool_calls =
      items
      |> Enum.filter(&match?(%{"type" => "function_call"}, &1))
      |> Enum.map(&output_tool_call/1)

    if tool_calls != [] do
      {:ok, :tool, tool_calls}
    else
      text = output_text(items)
      {:ok, :msg, text, total_tokens}
    end
  end

  # Fallback clause for unexpected response shapes
  defp get_response(unexpected) do
    {:error,
     %{
       http_status: 500,
       error: "Unexpected response #{inspect(unexpected)}"
     }}
  end

  # A Responses function_call item carries `call_id`. Internal callers expect
  # the chat-completions-style id-at-top-level + nested function map shape.
  defp output_tool_call(%{"type" => "function_call"} = item) do
    %{
      id: item["call_id"] || item["id"],
      function: %{
        name: item["name"],
        arguments: item["arguments"] || "{}"
      }
    }
  end

  defp output_text(items) do
    items
    |> Enum.filter(&match?(%{"type" => "message"}, &1))
    |> Enum.flat_map(fn item -> List.wrap(item["content"]) end)
    |> Enum.filter(&match?(%{"type" => "output_text"}, &1))
    |> Enum.map(&Map.get(&1, "text", ""))
    |> Enum.join("")
  end

  defp get_error(:closed), do: {:error, "Connection closed"}
  defp get_error(:timeout), do: {:error, "Connection timed out"}
  defp get_error(:invalid_json_response), do: {:error, "Invalid JSON response"}

  defp get_error({502, reason}), do: {:error, :api_unavailable, reason}
  defp get_error({503, reason}), do: {:error, :api_unavailable, reason}
  defp get_error({504, reason}), do: {:error, :api_unavailable, reason}

  defp get_error({http_status, json_error_string}) do
    json_error_string
    |> SafeJson.decode()
    |> case do
      {:ok, %{"error" => %{"message" => msg, "code" => "context_length_exceeded"}}} ->
        ~r/Your messages resulted in (\d+) tokens/
        |> Regex.run(msg)
        |> case do
          nil -> {:error, :context_length_exceeded, -1}
          [_, used] -> {:error, :context_length_exceeded, String.to_integer(used)}
        end

      {:ok, %{"error" => %{"code" => code, "message" => msg}}} ->
        {:error,
         %{
           http_status: http_status,
           code: code,
           message: msg
         }}

      {:ok, error} ->
        {:error,
         %{
           http_status: http_status,
           error: inspect(error, pretty: true)
         }}

      {:error, _} ->
        {:error,
         %{
           http_status: http_status,
           error: json_error_string
         }}
    end
  end

  # Catch-all for non-tuple errors: convert to binary
  defp get_error(other) when not is_tuple(other), do: {:error, to_string(other)}

  # Catch-all for other error tuples: inspect for debugging
  defp get_error(other), do: {:error, inspect(other, pretty: true)}
end

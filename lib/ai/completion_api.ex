defmodule AI.CompletionAPI do
  @moduledoc """
  Chat-completion request orchestration.

  Today this module owns both orchestration (build payload, post, parse)
  and OpenAI-specific knowledge (header shape, payload field names,
  response shape, env-var names for the API key). Stage 1 of the Venice
  port hoists the provider-specific concerns into per-provider behaviour
  modules; this Stage 0 implementation is OpenAI-only by construction
  but routes its `AI.Endpoint` behaviour callbacks (path + error
  classifier) through `AI.Provider` so the retry harness already pivots
  on the active provider.
  """

  @behaviour AI.Endpoint

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

  # ---------------------------------------------------------------------------
  # AI.Endpoint behaviour callbacks.
  #
  # Both callbacks defer to whichever endpoint module the active provider
  # exposes. The retry harness (`AI.Endpoint.post_json/3`) is the only
  # caller; it uses these to compute the URL and to classify errors.
  # ---------------------------------------------------------------------------

  @impl AI.Endpoint
  def endpoint_path, do: apply(provider_endpoint(), :endpoint_path, [])

  @doc """
  Delegate provider-specific error classification to the active provider's
  endpoint module. The behaviour contract is documented in `AI.Endpoint`.
  """
  @impl AI.Endpoint
  def endpoint_error_classify(status, body, headers, transport_reason) do
    apply(provider_endpoint(), :endpoint_error_classify, [
      status,
      body,
      headers,
      transport_reason
    ])
  end

  # Resolve the active provider's endpoint module. Indirected via
  # `apply/3` at the call sites above so the compiler does not try to
  # statically resolve the function on the union of all possible modules
  # `module_for/1` might return - which today is just `AI.Endpoint.OpenAI`
  # but logically widens to every endpoint module across providers. The
  # `apply` form is the same pattern `AI.Model` uses for its profile
  # factory dispatch.
  defp provider_endpoint, do: AI.Provider.module_for(:endpoint)

  @spec get(model, msgs, tools, response_format, web_search?, verbosity) :: response
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

    # ----------------------------------------------------------------------
    # Payload assembly.
    #
    # Each `Map.merge/2` below either contributes a provider field or
    # contributes nothing; this keeps the payload free of `nil`-valued keys
    # that the API would reject on strict providers.
    #
    # Capability flags on `model` gate the optional fields. The flags are
    # the source of truth for "can the wire format carry this?", so the
    # request builder consults them rather than pattern-matching on model-
    # name strings (which change between vendor releases).
    #
    # If a caller asks for web_search against a model that cannot perform
    # it, that is a programming error - the caller picked the wrong profile.
    # We raise here to surface the bug at the call site rather than letting
    # the request fly off and produce a confusing API error.
    # ----------------------------------------------------------------------
    if web_search? and not Map.get(model, :supports_web_search, false) do
      raise ArgumentError,
            "web_search? requested but model #{inspect(model.model)} does not " <>
              "support web search. Use AI.Model.web_search() or another " <>
              "web-search-capable profile."
    end

    payload =
      %{
        model: model.model,
        messages: msgs,
        response_format: response_format
      }
      |> Map.merge(
        case tools do
          nil -> %{}
          tools -> %{tools: tools}
        end
      )
      |> Map.merge(reasoning_effort_field(model))
      |> Map.merge(
        case verbosity do
          nil -> %{}
          value -> %{verbosity: value}
        end
      )
      |> Map.merge(
        if web_search? do
          %{web_search_options: %{}}
        else
          %{}
        end
      )

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

  # Resolve the reasoning_effort field for the request payload.
  #
  # Two gates:
  #   1. The model must declare `supports_reasoning: true`. Without it, no
  #      reasoning_effort field is emitted regardless of `model.reasoning`.
  #      This prevents the API from rejecting the request on models that
  #      don't accept the field (4.1 family, mini/nano variants).
  #   2. The level itself must map to a wire string. OpenAI accepts
  #      "low" / "medium" / "high" today. Future levels (`:minimal`,
  #      `:none`) round to nothing or to a sibling level depending on
  #      what the model accepts; the safest behavior is to omit the field
  #      so we leave it unmapped here. When OpenAI ships acceptance for
  #      `"minimal"`, add the case below.
  @spec reasoning_effort_field(AI.Model.t()) :: map
  defp reasoning_effort_field(%{supports_reasoning: false}), do: %{}

  defp reasoning_effort_field(%{reasoning: level}) do
    case level do
      :low -> %{reasoning_effort: "low"}
      :medium -> %{reasoning_effort: "medium"}
      :high -> %{reasoning_effort: "high"}
      # Unknown / unmapped level on a reasoning-capable model: omit the
      # field rather than guess. The model's default reasoning behavior
      # then applies.
      _ -> %{}
    end
  end

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

  defp get_response(%{"choices" => [%{"message" => response}], "usage" => usage}) do
    response
    |> Map.put("usage", usage)
    |> get_response()
  end

  defp get_response(%{"tool_calls" => tool_calls}) do
    {:ok, :tool, Enum.map(tool_calls, &get_tool_call/1)}
  end

  defp get_response(%{"content" => response, "usage" => usage}) do
    # Return total_tokens for backward compatibility
    total_tokens = Map.get(usage, "total_tokens", 0)
    {:ok, :msg, response, total_tokens}
  end

  # Fallback clause for unexpected response shapes
  defp get_response(unexpected) do
    {:error,
     %{
       http_status: 500,
       error: "Unexpected response #{inspect(unexpected)}"
     }}
  end

  defp get_tool_call(%{"id" => id, "function" => %{"name" => name, "arguments" => args}}) do
    %{id: id, function: %{name: name, arguments: args}}
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

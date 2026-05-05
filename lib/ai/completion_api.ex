defmodule AI.CompletionAPI do
  @moduledoc """
  Chat-completion request orchestration.

  This module is the thin spine that connects fnord's abstract request
  shape (model + messages + optional tools/response_format/web_search/
  verbosity) to the underlying provider's HTTP API. It owns:

  - Delegating to the active provider's `AI.Provider.RequestBuilder` for
    headers and payload assembly
  - Calling the retry harness (`AI.Endpoint.post_json/3`)
  - Delegating to the active provider's `AI.Provider.ResponseParser` for
    success-path and error-path body parsing
  - Implementing `AI.Endpoint`'s callbacks (`endpoint_path/0` and
    `endpoint_error_classify/4`) by routing through `AI.Provider` so the
    retry harness picks up the active provider automatically

  Provider-specific concerns - what the JSON body looks like, which env
  vars hold the API key, how citations are surfaced - all live in the
  provider's request-builder and response-parser modules. This module
  is deliberately ignorant of any of that.

  ## Why orchestration is centralized here

  The retry harness is provider-agnostic but the call site needs a single
  module to declare as the `AI.Endpoint` behaviour implementation (the
  retry harness uses the module name as a dispatch token). Centralizing
  orchestration here means there is exactly one such token, regardless
  of how many providers we ship.
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
  # The `apply/3` indirection sidesteps a static-analysis warning that
  # otherwise fires on the dynamic dispatch.
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

  # ---------------------------------------------------------------------------
  # Public entry point.
  #
  # Build a request via the active provider's request builder, post it
  # through the retry harness, and dispatch the result via the active
  # provider's response parser. Errors that escape both layers (e.g.
  # unexpected runtime exceptions during dispatch) are caught and wrapped
  # so the orchestration loop in `AI.Completion` always sees a typed
  # tuple, never a raw exception.
  # ---------------------------------------------------------------------------

  @spec get(model, msgs, tools, response_format, web_search?, verbosity) :: response
  def get(
        model,
        msgs,
        tools \\ nil,
        response_format \\ nil,
        web_search? \\ false,
        verbosity \\ nil
      ) do
    builder = provider_request_builder()
    parser = provider_response_parser()

    api_key = apply(builder, :api_key!, [])
    headers = apply(builder, :build_headers, [api_key])

    payload =
      apply(builder, :build_payload, [
        model,
        msgs,
        tools,
        response_format,
        web_search?,
        verbosity
      ])

    try do
      AI.Endpoint.post_json(__MODULE__, headers, payload)
      |> dispatch_post_result(parser)
    rescue
      e in RuntimeError -> wrap_unexpected("Runtime error", e, __STACKTRACE__)
      e in ArgumentError -> wrap_unexpected("Argument error", e, __STACKTRACE__)
      e -> wrap_unexpected("Unexpected error", e, __STACKTRACE__)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers.
  # ---------------------------------------------------------------------------

  # Resolve the active provider's endpoint module. The `apply/3` call
  # sites at the behaviour callbacks above use this rather than a direct
  # function call so static analysis does not try to prove the function
  # exists on the union of all possible modules `module_for/1` might
  # return - which today is just `AI.Endpoint.OpenAI` but logically
  # widens to every endpoint module across providers.
  defp provider_endpoint, do: AI.Provider.module_for(:endpoint)

  defp provider_request_builder, do: AI.Provider.module_for(:request_builder)

  defp provider_response_parser, do: AI.Provider.module_for(:response_parser)

  # Translate the post-result tuple into the orchestration layer's
  # tagged tuples. The three outcomes are:
  #
  #   {:ok, %{body: ...}} -> dispatch the body through the provider's
  #     response parser
  #   {:http_error, {status, body}} -> let the response parser produce
  #     the right error tuple, but pass the special context_length and
  #     message-shaped errors through unchanged
  #   {:transport_error, reason} -> map to a binary error string for
  #     the orchestration layer's logger
  defp dispatch_post_result({:ok, %{body: body}}, parser) do
    apply(parser, :parse_success, [body])
  end

  defp dispatch_post_result({:http_error, {status, body}}, parser) do
    case apply(parser, :parse_error, [status, body]) do
      {:error, :context_length_exceeded, _usage} = err ->
        err

      {:error, :api_unavailable, _reason} = err ->
        err

      {:error, %{message: msg}} = err ->
        # Surface the user-facing message at log time so a flaky API
        # produces a single readable error line in the operator's
        # terminal instead of a wall of inspected error map text.
        UI.error("HTTP error from upstream: #{msg}")
        err

      other ->
        other
    end
  end

  defp dispatch_post_result({:transport_error, error}, _parser) do
    transport_error_to_binary(error)
  end

  # Map low-level transport errors to user-facing strings. Anything not
  # explicitly recognized is passed through `inspect/2` so the operator
  # at least sees the raw atom rather than nothing.
  defp transport_error_to_binary(:closed), do: {:error, "Connection closed"}
  defp transport_error_to_binary(:timeout), do: {:error, "Connection timed out"}
  defp transport_error_to_binary(:invalid_json_response), do: {:error, "Invalid JSON response"}
  defp transport_error_to_binary(other) when not is_tuple(other), do: {:error, to_string(other)}
  defp transport_error_to_binary(other), do: {:error, inspect(other, pretty: true)}

  # Wrap an unexpected exception into the orchestration layer's structured
  # error map. The orchestration loop matches on `:http_status` and
  # `:error`, so we synthesize a 500 to fit that shape rather than
  # introducing yet another error variant for "the request layer crashed."
  defp wrap_unexpected(label, exception, stacktrace) do
    {:error,
     %{
       http_status: 500,
       error: """
       #{label}: #{Exception.message(exception)}
       #{Exception.format_stacktrace(stacktrace)}
       """
     }}
  end
end

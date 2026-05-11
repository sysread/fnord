defmodule AI.Provider.ResponseParser.OpenAI do
  @moduledoc """
  OpenAI implementation of the `AI.Provider.ResponseParser` behaviour.

  Parses the OpenAI chat-completion response shape:

      %{
        "choices" => [%{"message" => %{...}}],
        "usage" => %{"total_tokens" => N, ...}
      }

  Successful messages may carry either `content` (text) or `tool_calls`
  (tool invocation requests). The two paths produce different result
  tuples (`{:ok, :msg, ...}` vs `{:ok, :tool, ...}`), which the
  orchestration loop in `AI.Completion` dispatches on.

  ## Error parsing

  Errors arrive as a JSON-encoded `error` object with a `code` field. The
  `context_length_exceeded` code is special-cased because the
  orchestration layer needs the used-token count to drive compaction;
  every other code passes through as a structured map error.

  Some upstream intermediaries (Cloudflare in particular) return
  plaintext bodies for 5xx; the bottom of the case expression catches
  these and surfaces them as a binary error so the user sees real text
  instead of a JSON-decode failure.
  """

  @behaviour AI.Provider.ResponseParser

  @impl AI.Provider.ResponseParser
  def parse_success(body) do
    get_response(body)
  end

  @impl AI.Provider.ResponseParser
  def parse_error(http_status, body) when is_binary(body) do
    parse_http_error_body(http_status, body)
  end

  # Defensive catch-all for non-binary bodies (test mocks, future
  # refactors, or transport layers that decode the body before handing
  # it to the parser). Without this clause a non-binary body produces a
  # `FunctionClauseError` rather than the typed error tuple downstream
  # callers expect.
  def parse_error(http_status, body) do
    {:error, %{http_status: http_status, error: inspect(body, pretty: true)}}
  end

  # ---------------------------------------------------------------------------
  # Success-path response shape walking.
  #
  # The OpenAI response carries the assistant's reply nested inside
  # `choices[0].message`. We unwrap progressively: choices+usage ->
  # message+usage -> tool_calls or content. Each clause matches the
  # specific shape it expects so a malformed response falls through to
  # the catch-all and surfaces as a structured error.
  # ---------------------------------------------------------------------------
  defp get_response(%{"choices" => [%{"message" => response}], "usage" => usage}) do
    response
    |> Map.put("usage", usage)
    |> get_response()
  end

  defp get_response(%{"tool_calls" => tool_calls}) do
    {:ok, :tool, Enum.map(tool_calls, &get_tool_call/1)}
  end

  defp get_response(%{"content" => response, "usage" => usage}) do
    # Surface total_tokens for backward compatibility with callers that
    # treat usage as a single integer rather than a structured object.
    total_tokens = Map.get(usage, "total_tokens", 0)
    {:ok, :msg, response, total_tokens}
  end

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

  # ---------------------------------------------------------------------------
  # Error-path body parsing.
  #
  # The 502/503/504 codes get special treatment - they represent transient
  # upstream unavailability rather than a logical error from the model,
  # so we surface them with the `:api_unavailable` tag so the
  # orchestration layer can render a "try again later" message instead
  # of producing a noisy structured error.
  # ---------------------------------------------------------------------------
  defp parse_http_error_body(502, reason), do: {:error, :api_unavailable, reason}
  defp parse_http_error_body(503, reason), do: {:error, :api_unavailable, reason}
  defp parse_http_error_body(504, reason), do: {:error, :api_unavailable, reason}

  defp parse_http_error_body(http_status, json_error_string) do
    json_error_string
    |> SafeJson.decode()
    |> case do
      {:ok, %{"error" => %{"message" => msg, "code" => "context_length_exceeded"}}} ->
        # The orchestration layer's compaction step needs the token
        # count. Extract from the error message (the only place OpenAI
        # surfaces it for this error code) when present; fall back to
        # -1 to signal "unknown."
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
        # Plaintext body (Cloudflare et al.). Surface verbatim so the
        # user can see what the intermediary actually said.
        {:error,
         %{
           http_status: http_status,
           error: json_error_string
         }}
    end
  end
end

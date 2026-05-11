defmodule AI.Provider.ResponseParser.DeepSeek do
  @moduledoc """
  DeepSeek implementation of the `AI.Provider.ResponseParser` behaviour.

  DeepSeek is OpenAI-API-compatible at the response shape: `choices`,
  `message`, `usage`. The parser mirrors the OpenAI parser at the
  success path; on the error path, 429s surface as typed `:throttled`
  and 502/503/504 as `:api_unavailable`.

  ## Differences from the OpenAI parser

  - No `context_length_exceeded` extraction. DeepSeek's out-of-context
    error format has not been observed yet; when one is captured, wire
    up the extraction here.
  - No Cloudflare-plaintext fallback path.
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

  def parse_error(http_status, body) do
    {:error, %{http_status: http_status, error: inspect(body, pretty: true)}}
  end

  # ---------------------------------------------------------------------------
  # Success-path response shape walking.
  # ---------------------------------------------------------------------------
  defp get_response(%{"choices" => [%{"message" => response}], "usage" => usage}) do
    response
    |> Map.put("usage", usage)
    |> get_response()
  end

  defp get_response(%{"tool_calls" => tool_calls}) when not is_nil(tool_calls) do
    {:ok, :tool, Enum.map(tool_calls, &get_tool_call/1)}
  end

  # DeepSeek's thinking-mode models surface chain-of-thought under
  # `reasoning_content` alongside the final `content`. The field MUST
  # be round-tripped on subsequent turns or DeepSeek rejects with
  # "The reasoning_content in the thinking mode must be passed back
  # to the API." Surface it as a 5-tuple so the orchestration layer
  # can attach it to the assistant message in state.messages.
  defp get_response(%{"content" => response, "reasoning_content" => rc, "usage" => usage})
       when is_binary(rc) and rc != "" do
    total_tokens = Map.get(usage, "total_tokens", 0)
    {:ok, :msg, response, total_tokens, rc}
  end

  defp get_response(%{"content" => response, "usage" => usage}) do
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
  # ---------------------------------------------------------------------------
  defp parse_http_error_body(502, reason), do: {:error, :api_unavailable, reason}
  defp parse_http_error_body(503, reason), do: {:error, :api_unavailable, reason}
  defp parse_http_error_body(504, reason), do: {:error, :api_unavailable, reason}

  defp parse_http_error_body(429, json_error_string) do
    reason =
      case SafeJson.decode(json_error_string) do
        {:ok, %{"error" => %{"message" => msg}}} when is_binary(msg) -> msg
        {:ok, %{"error" => msg}} when is_binary(msg) -> msg
        _ -> json_error_string
      end

    {:error, :throttled, reason}
  end

  defp parse_http_error_body(http_status, json_error_string) do
    json_error_string
    |> SafeJson.decode()
    |> case do
      {:ok, %{"error" => %{"code" => code, "message" => msg}}} ->
        {:error,
         %{
           http_status: http_status,
           code: code,
           message: msg
         }}

      {:ok, %{"error" => %{"message" => msg}}} ->
        {:error,
         %{
           http_status: http_status,
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
end

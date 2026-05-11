defmodule AI.Provider.ResponseParser.Venice do
  @moduledoc """
  Venice implementation of the `AI.Provider.ResponseParser` behaviour.

  Parses the Venice chat-completion response shape, which mirrors
  OpenAI's at the `choices`/`message` level but adds two Venice-specific
  features that this parser surfaces:

  - **Web search citations**: when web search was enabled,
    `venice_parameters.web_search_citations` is an array of
    `{title, url, content, date}` objects. The assistant `content`
    contains inline `^N^` superscript markers that reference array
    positions. We append a deterministic numbered "Sources:" section to
    the message text so callers consuming the existing
    `{:ok, :msg, binary, usage}` contract see the citations without any
    orchestration-layer changes.
  - **Reasoning token accounting**: usage carries
    `completion_tokens_details.reasoning_tokens` separately. We surface
    the existing `total_tokens` field for backward compatibility; the
    detailed breakdown is available in the body if a caller wants it
    later.

  ## Why citations are appended to text rather than carried structurally

  The orchestration layer (`AI.Completion`) treats each completion as
  `{:ok, :msg, binary, usage}` end-to-end. Extending the contract to
  carry citations as a separate field would ripple through every
  consumer (15+ agents, output module, replay, conversation
  persistence, tool-call dispatch). Appending to the text is zero
  ripple and the inline `^N^` markers Venice emits in `content` line up
  naturally with a numbered list. Promotion to structured citations is
  possible later if richer rendering is wanted.

  ## Error parsing

  Venice's error JSON shape is OpenAI-compatible (`error.message`,
  `error.code`). We share most of the parsing logic with the OpenAI
  parser, with two Venice deltas:

  - **402 Payment Required** is special: surfaced with a clear message
    rather than a raw inspected error map, so the user sees the
    insufficient-balance signal in plaintext.
  - **No `context_length_exceeded` extraction.** Venice's
    out-of-context error code differs from OpenAI's; we leave it as a
    structured map error for now. If compaction-on-overflow becomes
    important on Venice, add a regex-based extraction here.
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
  # Success-path body walking.
  #
  # The shape is choices.[0].message + usage at the top level, plus a
  # top-level venice_parameters that carries citation data. We extract
  # the usage and (if present) citations once at the top and thread them
  # into the inner walk so the message-level functions can apply both.
  # ---------------------------------------------------------------------------
  defp get_response(%{"choices" => [%{"message" => message}]} = body) do
    usage = Map.get(body, "usage", %{})
    citations = extract_citations(body)
    walk_message(message, usage, citations)
  end

  defp get_response(unexpected) do
    {:error,
     %{
       http_status: 500,
       error: "Unexpected response #{inspect(unexpected)}"
     }}
  end

  # Tool calls take precedence over content - if the model invoked a
  # tool, that is the meaningful payload regardless of whether content
  # is also present.
  defp walk_message(%{"tool_calls" => nil}, _usage, _citations) do
    {:ok, :tool, []}
  end

  defp walk_message(%{"tool_calls" => tool_calls}, _usage, _citations) do
    {:ok, :tool, Enum.map(tool_calls, &get_tool_call/1)}
  end

  defp walk_message(%{"content" => text}, usage, citations) do
    total_tokens = Map.get(usage, "total_tokens", 0)
    text = append_citations(text, citations)
    {:ok, :msg, text, total_tokens}
  end

  defp walk_message(unexpected, _usage, _citations) do
    {:error,
     %{
       http_status: 500,
       error: "Unexpected message shape #{inspect(unexpected)}"
     }}
  end

  defp get_tool_call(%{"id" => id, "function" => %{"name" => name, "arguments" => args}}) do
    %{id: id, function: %{name: name, arguments: args}}
  end

  # ---------------------------------------------------------------------------
  # Citation handling.
  #
  # Citations live at body.venice_parameters.web_search_citations. When
  # present and non-empty, we append a numbered "Sources:" section to
  # the assistant text. The numbering uses 1-based indexing to match
  # the inline `^N^` markers Venice emits in the message body.
  # ---------------------------------------------------------------------------
  defp extract_citations(body) do
    body
    |> Map.get("venice_parameters", %{})
    |> Map.get("web_search_citations", [])
  end

  defp append_citations(text, []), do: text
  defp append_citations(text, nil), do: text

  defp append_citations(text, citations) when is_list(citations) do
    sources =
      citations
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {citation, idx} ->
        # Each citation may carry partial fields; render whichever are
        # present without raising on missing keys.
        title = Map.get(citation, "title", "")
        url = Map.get(citation, "url", "")
        format_citation_line(idx, title, url)
      end)

    text <> "\n\nSources:\n" <> sources
  end

  defp format_citation_line(idx, "", url), do: "#{idx}. #{url}"
  defp format_citation_line(idx, title, ""), do: "#{idx}. #{title}"
  defp format_citation_line(idx, title, url), do: "#{idx}. #{title} - #{url}"

  # ---------------------------------------------------------------------------
  # Error-path body parsing.
  #
  # 402 (Payment Required) is the headline Venice-specific error - flag
  # it explicitly so the user sees a clear payment-required message
  # rather than a generic inspected map.
  # ---------------------------------------------------------------------------
  defp parse_http_error_body(402, _body) do
    {:error,
     %{
       http_status: 402,
       code: "payment_required",
       message:
         "Venice reports insufficient balance for this request. " <>
           "Top up your wallet at https://venice.ai/settings/billing."
     }}
  end

  defp parse_http_error_body(http_status, json_error_string)
       when http_status in [502, 503, 504] do
    {:error, :api_unavailable, json_error_string}
  end

  defp parse_http_error_body(http_status, json_error_string) do
    case SafeJson.decode(json_error_string) do
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
        # Plaintext body. Surface verbatim.
        {:error,
         %{
           http_status: http_status,
           error: json_error_string
         }}
    end
  end
end

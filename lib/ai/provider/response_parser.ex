defmodule AI.Provider.ResponseParser do
  @moduledoc """
  Behaviour for turning raw HTTP responses into the completion-level
  result tuples the rest of fnord understands.

  ## The two paths

  A chat-completion call ends in one of two states from the HTTP layer's
  perspective: a 2xx with a body (`parse_success/1`) or a non-2xx with a
  body (`parse_error/2`). The parser turns each into the tagged tuples
  the `AI.Completion` orchestration loop knows how to handle:

    - `{:ok, :msg, text, usage}` - assistant produced text
    - `{:ok, :tool, tool_calls}` - assistant requested tool calls
    - `{:error, :context_length_exceeded, used_tokens}` - the special-
      case error that triggers compaction in `AI.Completion`
    - `{:error, %{...}}` or `{:error, binary}` - everything else

  ## Provider-specific concerns

  The OpenAI shape (`choices.[0].message.content` or `tool_calls`) is the
  baseline; Venice mirrors it but adds `venice_parameters.web_search_-
  citations` that we surface by appending a "Sources:" section to the
  assistant text. Each provider's parser owns those local quirks.

  ## Transport errors

  The transport-error path (connection closed, TLS failure, etc.) is
  classified upstream by `AI.Endpoint`'s retry harness using the
  endpoint's `endpoint_error_classify/4`. Anything that survives retry
  reaches `parse_error/2` here as an HTTP status + body, OR reaches the
  orchestration layer as a transport-error tuple it handles directly.
  """

  @type model :: AI.Model.t()
  @type usage :: non_neg_integer

  @type msg_response :: {:ok, :msg, binary, usage}
  @type tool_response :: {:ok, :tool, list(map)}

  @type error_response ::
          {:error, map}
          | {:error, binary}
          | {:error, :context_length_exceeded, non_neg_integer}
          | {:error, :api_unavailable, any}

  @type response :: msg_response | tool_response | error_response

  @doc """
  Parse a 2xx response body. Body has already been JSON-decoded by the
  HTTP layer.
  """
  @callback parse_success(body :: map) :: response

  @doc """
  Parse a non-2xx response. Receives the HTTP status and the raw body
  string (typically JSON, but the implementation should be defensive
  because some intermediaries return plaintext).
  """
  @callback parse_error(http_status :: integer, body :: binary) :: error_response
end

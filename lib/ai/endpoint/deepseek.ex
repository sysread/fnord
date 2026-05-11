defmodule AI.Endpoint.DeepSeek do
  @moduledoc """
  DeepSeek endpoint implementation.

  DeepSeek's chat-completions API is OpenAI-API-compatible at the
  wire surface. The single configured model in fnord's catalog is
  `deepseek-v4-flash` (1M context, reasoning-capable, no web search).

  ## Error model deltas vs. OpenAI

  - No documented Cloudflare-plaintext branch; uncovered shapes pass
    through as `:ok` so the retry harness treats them as terminal.
  - 429s are surfaced as `:throttled` with no body-derived wait hint
    today; if DeepSeek starts shipping `Retry-After` or rate-limit
    reset headers, parse them here.
  - No payment-required (402) special-case.
  """

  @behaviour AI.Endpoint

  @base_url "https://api.deepseek.com"

  @impl AI.Endpoint
  @spec endpoint_path() :: String.t()
  def endpoint_path, do: "#{@base_url}/chat/completions"

  @impl AI.Endpoint
  @spec endpoint_error_classify(integer | nil, binary | nil, list | nil, term | nil) ::
          :ok | {:retry, atom, non_neg_integer | nil} | {:fail, atom, binary}
  def endpoint_error_classify(status, body, _headers, transport_reason) do
    case {status, body, transport_reason} do
      {nil, nil, :timeout} -> {:retry, :network_glitch, nil}
      {nil, nil, :closed} -> {:retry, :network_glitch, nil}
      {nil, nil, {:tls_alert, _}} -> {:retry, :network_glitch, nil}
      {nil, nil, {:ssl, _}} -> {:retry, :network_glitch, nil}
      {429, _b, _} -> {:retry, :throttled, nil}
      {s, _b, _} when is_integer(s) and s >= 500 and s < 600 ->
        {:retry, :server_error, nil}

      {401, _b, _} -> {:fail, :unauthorized, "Unauthorized"}
      {403, _b, _} -> {:fail, :forbidden, "Forbidden"}
      _ -> :ok
    end
  end
end

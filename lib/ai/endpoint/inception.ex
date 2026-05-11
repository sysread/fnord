defmodule AI.Endpoint.Inception do
  @moduledoc """
  Inception Labs endpoint implementation.

  Inception is OpenAI-API-compatible at the chat-completions surface,
  with a single hosted model (`mercury-2`, 128K context). The endpoint
  classifier mirrors the OpenAI flavor for the conditions we have seen
  documented; uncovered cases pass through as :ok so the retry harness
  treats them as terminal until evidence justifies retrying.

  ## Error model deltas vs. OpenAI

  - Inception does not front through Cloudflare in a documented way -
    no plaintext-body retry branch.
  - No payment-required (402) special-case; Inception's billing model
    is API-key-only (no per-request wallet auth).
  - 429s are surfaced as `:throttled` with no body-derived wait hint -
    if Inception ships rate-limit metadata in the future, parse it
    here.
  """

  @behaviour AI.Endpoint

  @base_url "https://api.inceptionlabs.ai"

  @impl AI.Endpoint
  @spec endpoint_path() :: String.t()
  def endpoint_path, do: "#{@base_url}/v1/chat/completions"

  @impl AI.Endpoint
  @spec endpoint_error_classify(integer | nil, binary | nil, list | nil, term | nil) ::
          :ok | {:retry, atom, non_neg_integer | nil} | {:fail, atom, binary}
  def endpoint_error_classify(status, body, _headers, transport_reason) do
    case {status, body, transport_reason} do
      {nil, nil, :timeout} -> {:retry, :network_glitch, nil}
      {nil, nil, :closed} -> {:retry, :network_glitch, nil}
      {nil, nil, {:tls_alert, _}} -> {:retry, :network_glitch, nil}
      {nil, nil, {:ssl, _}} -> {:retry, :network_glitch, nil}
      # Throttling. No documented Retry-After header today; rely on the
      # harness's backoff schedule.
      {429, _b, _} -> {:retry, :throttled, nil}
      # Server-side problems retry-and-hope.
      {s, _b, _} when is_integer(s) and s >= 500 and s < 600 ->
        {:retry, :server_error, nil}

      {401, _b, _} -> {:fail, :unauthorized, "Unauthorized"}
      {403, _b, _} -> {:fail, :forbidden, "Forbidden"}
      _ -> :ok
    end
  end
end

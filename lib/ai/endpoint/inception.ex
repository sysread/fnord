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
  - 429s are surfaced as `:throttled`. When the response body contains
    the phrase `input token limit`, the classifier returns a long
    initial wait (60s) because the underlying budget is a per-minute
    aggregate that does NOT recover within the standard backoff
    schedule (~10s total). The default ~500ms / ~5s / ~10s pattern
    just burns three retries before the per-minute budget has had any
    chance to reset, and each retry re-sends the full input payload -
    deepening the token spend rather than relieving it. A single
    60s wait matches the reset window. Other 429s fall back to the
    harness's default backoff.
  """

  @behaviour AI.Endpoint

  @base_url "https://api.inceptionlabs.ai"

  # Wait hint for `input token limit exceeded` 429s. Inception's input
  # token budget is per-minute; the standard backoff cannot outwait it.
  # 60s aligns the first retry with the typical reset boundary.
  @input_token_limit_wait_ms 60_000

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
      # Throttling. Special-case the per-minute input-token-limit
      # variant with a 60s wait; ordinary 429s fall through to the
      # harness's default backoff.
      {429, b, _} when is_binary(b) ->
        if input_token_limit?(b) do
          {:retry, :throttled, @input_token_limit_wait_ms}
        else
          {:retry, :throttled, nil}
        end

      {429, _b, _} ->
        {:retry, :throttled, nil}

      # Server-side problems retry-and-hope.
      {s, _b, _} when is_integer(s) and s >= 500 and s < 600 ->
        {:retry, :server_error, nil}

      {401, _b, _} -> {:fail, :unauthorized, "Unauthorized"}
      {403, _b, _} -> {:fail, :forbidden, "Forbidden"}
      _ -> :ok
    end
  end

  # Inception surfaces aggregate input-token rate limits as a 429 whose
  # body contains the phrase `input token limit` (e.g. "Rate limit
  # reached: input token limit exceeded"). Match the substring rather
  # than parsing the full JSON shape so a wording tweak on Inception's
  # side does not silently drop the special-case.
  @spec input_token_limit?(binary) :: boolean
  defp input_token_limit?(body) when is_binary(body) do
    String.contains?(String.downcase(body), "input token limit")
  end
end

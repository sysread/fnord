defmodule AI.Endpoint.Venice do
  @moduledoc """
  Venice-specific endpoint implementation.

  Provides the endpoint URL and error classification used by
  `AI.Endpoint`'s centralized retry/backoff logic.

  ## Error model deltas vs. OpenAI

  Venice's error model is similar to OpenAI's at the broad strokes
  (4xx are user errors, 5xx are server errors, 429 is throttling) but
  differs in the specifics:

  - **402 Payment Required** is unique to Venice's x402 wallet auth.
    When the user's balance is insufficient, Venice returns 402 with a
    structured payload describing how to top up. Retrying does not help
    - the request will keep failing until the wallet is funded - so we
    classify 402 as `{:fail, :payment_required, ...}`.
  - **No Cloudflare-plaintext branch.** Venice does not front through
    Cloudflare in the same way as OpenAI; the Cloudflare-specific
    plaintext detection in `AI.Endpoint.OpenAI` is dead weight here.
  - **504 Gateway Timeout** documentation suggests using streaming for
    long-running requests. fnord does not stream today; we retry-and-
    hope, which is the safest behavior absent a streaming refactor.

  ## What we still share with the OpenAI classifier

  - 429 -> `{:retry, :throttled, wait_ms}`. Venice exposes
    `x-ratelimit-reset-{requests,tokens}` headers describing when each
    bucket refills; we pick the soonest positive reset and use it as
    the retry hint, falling back to the harness's exponential backoff
    when no useful header is present (e.g. on transient overload that
    lacks rate-limit metadata).
  - 5xx -> `{:retry, :server_error, nil}`.
  - 401/403 -> `{:fail, :unauthorized, ...}` / `{:fail, :forbidden, ...}`.
  - Transport errors (timeout, closed, TLS alerts) -> retry as
    network glitches.

  ## Rate-limit reset headers

  Venice's reset headers carry mixed semantics:

  - `x-ratelimit-reset-requests`: unix timestamp when the request
    window resets. Venice's docs describe this as a "Unix timestamp"
    without specifying units; observed traffic shows the value shipped
    in **ms-since-epoch** (`Date.now()` style), three orders of
    magnitude off the conventional seconds-since-epoch. To stay robust
    if Venice's implementation or docs converge later, the parser
    distinguishes by magnitude: integers above `1e11` are read as
    ms-since-epoch (year 5138 in seconds is below this threshold; year
    1973 in ms is also below it, so the boundary is unambiguous for
    any plausible reset value).
  - `x-ratelimit-reset-tokens`: integer seconds-until the token limit
    resets.

  Both are normalized to milliseconds-from-now and the smaller positive
  value wins (the bucket that refills sooner is the one we are blocked
  on). Negative values are clamped to zero - those describe a window
  that has already reset, in which case the harness should retry
  without further wait.
  """

  @behaviour AI.Endpoint

  @base_url "https://api.venice.ai"

  @impl AI.Endpoint
  @spec endpoint_path() :: String.t()
  def endpoint_path, do: "#{@base_url}/api/v1/chat/completions"

  @impl AI.Endpoint
  @spec endpoint_error_classify(integer | nil, binary | nil, list | nil, term | nil) ::
          :ok | {:retry, atom, non_neg_integer | nil} | {:fail, atom, binary}
  def endpoint_error_classify(status, body, headers, transport_reason) do
    case {status, body, transport_reason} do
      # Transport-level glitches: retry. Same set of reasons as the
      # OpenAI classifier - these are network conditions, not
      # provider-specific.
      {nil, nil, :timeout} -> {:retry, :network_glitch, nil}
      {nil, nil, :closed} -> {:retry, :network_glitch, nil}
      {nil, nil, {:tls_alert, _}} -> {:retry, :network_glitch, nil}
      {nil, nil, {:ssl, _}} -> {:retry, :network_glitch, nil}
      # Throttling. Prefer the structured reset hint from Venice's
      # rate-limit headers when present; the harness's backoff schedule
      # is the floor when no header is informative.
      {429, _b, _} -> {:retry, :throttled, retry_after_ms(headers)}
      # Server-side problems. 504 is documented as "use streaming for
      # long requests"; we retry-and-hope here since fnord does not
      # stream. If 504s become noisy, streaming is a separate project.
      {s, _b, _} when is_integer(s) and s >= 500 and s < 600 ->
        {:retry, :server_error, nil}

      # Hard fails. 402 is unique to Venice (x402 insufficient balance).
      # Retrying does not help; we want the user to see the payment-
      # required signal immediately.
      {402, _b, _} -> {:fail, :payment_required, "Payment required (insufficient balance)"}
      {401, _b, _} -> {:fail, :unauthorized, "Unauthorized"}
      {403, _b, _} -> {:fail, :forbidden, "Forbidden"}
      _ -> :ok
    end
  end

  # Translate Venice's rate-limit reset headers into a wait_ms hint.
  # Returns the smaller positive value among the two reset buckets, or
  # nil when neither header is present/parseable. The two headers carry
  # different units (unix timestamp vs. seconds-until); each is
  # normalized to ms-from-now before comparison.
  @spec retry_after_ms(list | nil) :: non_neg_integer | nil
  defp retry_after_ms(nil), do: nil

  defp retry_after_ms(headers) when is_list(headers) do
    map = Enum.into(headers, %{}, fn {k, v} -> {String.downcase(k), v} end)
    now_ms = System.system_time(:millisecond)

    candidates =
      [
        unix_ts_ms(Map.get(map, "x-ratelimit-reset-requests"), now_ms),
        seconds_ms(Map.get(map, "x-ratelimit-reset-tokens"))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&max(&1, 0))

    case candidates do
      [] -> nil
      ms_list -> Enum.min(ms_list)
    end
  end

  # Parse `x-ratelimit-reset-requests` into ms-from-now. The header is
  # documented as a "Unix timestamp" without a unit; Venice ships
  # ms-since-epoch in practice. We auto-detect by magnitude: above 1e11
  # is unambiguously ms-since-epoch (year 5138 in seconds vs year 1973
  # in ms), so either encoding is handled correctly without a flag.
  @ms_epoch_threshold 100_000_000_000
  @spec unix_ts_ms(binary | nil, non_neg_integer) :: integer | nil
  defp unix_ts_ms(nil, _now_ms), do: nil

  defp unix_ts_ms(value, now_ms) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {ts, _} when ts >= @ms_epoch_threshold -> ts - now_ms
      {ts_seconds, _} -> ts_seconds * 1000 - now_ms
      :error -> nil
    end
  end

  # Parse `x-ratelimit-reset-tokens` (seconds-until) into ms.
  @spec seconds_ms(binary | nil) :: integer | nil
  defp seconds_ms(nil), do: nil

  defp seconds_ms(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {seconds, _} -> seconds * 1000
      :error -> nil
    end
  end
end

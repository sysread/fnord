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

  - 429 -> `{:retry, :throttled, nil}`. We deliberately do NOT consult
    Venice's `x-ratelimit-reset-*` headers as a retry hint: Venice
    returns 429 for two distinct conditions - per-account rate limit
    *and* per-model backpressure ("model is currently overloaded") -
    and the reset headers describe only the former. Using them on
    backpressure 429s would force the harness to wait until the rate-
    limit window resets, which is wildly longer than the model's
    transient overload. The harness's exponential backoff handles both
    cases adequately.
  - 5xx -> `{:retry, :server_error, nil}`.
  - 401/403 -> `{:fail, :unauthorized, ...}` / `{:fail, :forbidden, ...}`.
  - Transport errors (timeout, closed, TLS alerts) -> retry as
    network glitches.
  """

  @behaviour AI.Endpoint

  @base_url "https://api.venice.ai"

  @impl AI.Endpoint
  @spec endpoint_path() :: String.t()
  def endpoint_path, do: "#{@base_url}/api/v1/chat/completions"

  @impl AI.Endpoint
  @spec endpoint_error_classify(integer | nil, binary | nil, list | nil, term | nil) ::
          :ok | {:retry, atom, non_neg_integer | nil} | {:fail, atom, binary}
  def endpoint_error_classify(status, body, _headers, transport_reason) do
    case {status, body, transport_reason} do
      # Transport-level glitches: retry. Same set of reasons as the
      # OpenAI classifier - these are network conditions, not
      # provider-specific.
      {nil, nil, :timeout} -> {:retry, :network_glitch, nil}
      {nil, nil, :closed} -> {:retry, :network_glitch, nil}
      {nil, nil, {:tls_alert, _}} -> {:retry, :network_glitch, nil}
      {nil, nil, {:ssl, _}} -> {:retry, :network_glitch, nil}
      # Throttling. 429 covers both rate limiting and model overload;
      # the harness's backoff schedule handles both adequately.
      {429, _b, _} -> {:retry, :throttled, nil}
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
end

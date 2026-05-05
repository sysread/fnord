defmodule AI.Provider.Health do
  @moduledoc """
  Behaviour for performing a per-provider health check.

  A health check verifies that the configured environment is in a
  workable state for the provider: the API key is set, the endpoint is
  reachable, and the credentials are valid. The contract is intentionally
  small so that adding a new provider does not require teaching the
  config command anything new about the provider's URL scheme or
  response shape.

  ## Why a separate behaviour

  `AI.Provider.RequestBuilder` already owns API key acquisition, but a
  health check is more than that - it also needs a network round trip
  to confirm the credential is live. Splitting it out keeps the
  request-builder focused on chat-completion plumbing and lets the
  health check evolve independently (e.g. adding latency reporting).

  ## Failure modes

  Implementations should return one of:

  - `{:ok, info}` - the API key is set, the endpoint is reachable, and
    the credentials are valid. `info` is a small map the config command
    will surface to the user (e.g. number of models available).
  - `{:error, :missing_api_key, message}` - the env vars are not set.
    Message names the env vars to fix.
  - `{:error, :unauthorized, message}` - the endpoint replied 401.
  - `{:error, :unreachable, message}` - the endpoint did not reply (DNS,
    timeout, TLS).
  - `{:error, :other, message}` - anything else, with a human-readable
    explanation.

  Implementations must not raise; the config command treats a raise as
  a bug in the implementation, not as a check failure.
  """

  @type info :: map
  @type reason :: :missing_api_key | :unauthorized | :unreachable | :other
  @type result :: {:ok, info} | {:error, reason, binary}

  @doc """
  Verify the provider's environment and credentials. Returns a small
  info map on success, a tagged reason on failure.
  """
  @callback check() :: result
end

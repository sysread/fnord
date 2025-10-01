defmodule MCP.OAuth2.Adapter do
  @moduledoc """
  Behaviour for DI-friendly OAuth2/OIDC Authorization Code + PKCE flow.

  This behaviour abstracts the "start flow" step so tests can inject a mock
  implementation and production can perform real discovery/flow creation.

  Responsibilities:
    - Provide a single entry point for beginning the auth flow and returning
      `{port, state, verifier, auth_url, redirect_uri}` semantics required by the
      loopback finalize path.

  Introduced: M3 (OAuth CLI orchestration, DI boundary).
  """

  @callback start_flow(map()) ::
              {:ok, non_neg_integer(), String.t(), String.t(), String.t(), String.t()}
              | {:error, term()}
end

defmodule MCP.OAuth2.Adapter.Default do
  @moduledoc """
  Default OAuth2/OIDC Authorization Code + PKCE adapter.

  Reserves an ephemeral 127.0.0.1 port, composes the loopback `redirect_uri`,
  and delegates to `MCP.OAuth2.OidccAdapter.start_flow/1`. Maps common provider
  rejections (e.g., HTTP 400 for redirect URIs) to actionable error tuples.

  Security:
    - Avoids logging sensitive values.
    - Redirect URIs use 127.0.0.1 ephemeral port per RFC 8252 guidance.

  Introduced: M3.
  """
  @behaviour MCP.OAuth2.Adapter

  @spec start_flow(map()) ::
          {:ok, non_neg_integer(), String.t(), String.t(), String.t(), String.t()}
          | {:error, term()}
  def start_flow(oauth) when is_map(oauth) do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, {:ip, {127, 0, 0, 1}}, {:active, false}, {:reuseaddr, true}])

    {:ok, {_addr, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)

    redirect_uri = "http://127.0.0.1:#{port}/callback"
    oauth2 = Map.put(oauth, :redirect_uri, redirect_uri)

    case MCP.OAuth2.OidccAdapter.start_flow(oauth2) do
      {:ok, %{auth_url: url, state: state, code_verifier: verifier}} ->
        {:ok, port, state, verifier, url, redirect_uri}

      {:error, {:http_error, 400}} ->
        {:error, {:provider_rejected_redirect, redirect_uri}}

      {:error, e} ->
        {:error, e}
    end
  end
end

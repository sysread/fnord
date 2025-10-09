defmodule MCP.OAuth2.Client do
  @moduledoc """
  Pure OAuth2 + PKCE client implementation for MCP servers.

  Unlike OIDC libraries (like oidcc), this works with OAuth2 Authorization Server
  discovery (RFC 8414) at `/.well-known/oauth-authorization-server`, not just
  OpenID Connect discovery at `/.well-known/openid-configuration`.

  Implements:
  - Authorization Code flow with PKCE (RFC 7636)
  - Token refresh (RFC 6749)
  - OAuth2 server metadata discovery (RFC 8414)

  Security:
  - PKCE is always required (S256 challenge method)
  - Tokens are never logged
  - Uses secure random generation for state and verifier
  """

  @type config :: %{
          required(:discovery_url) => String.t(),
          required(:client_id) => String.t(),
          optional(:client_secret) => String.t(),
          required(:redirect_uri) => String.t(),
          required(:scopes) => [String.t()]
        }

  @type tokens :: %{
          access_token: String.t(),
          token_type: String.t(),
          expires_at: non_neg_integer(),
          refresh_token: String.t() | nil,
          scope: String.t() | nil
        }

  @doc """
  Start OAuth2 authorization flow with PKCE.

  Fetches server metadata, generates PKCE parameters, and builds authorization URL.

  Returns: `{:ok, %{auth_url: String.t(), state: String.t(), code_verifier: String.t()}}`
  """
  @spec start_flow(config) ::
          {:ok, %{auth_url: String.t(), state: String.t(), code_verifier: String.t()}}
          | {:error, term()}
  def start_flow(cfg) do
    with {:ok, metadata} <- fetch_metadata(cfg.discovery_url),
         {:ok, state} <- generate_state(),
         {:ok, verifier, challenge} <- generate_pkce(),
         {:ok, auth_url} <- build_authorization_url(metadata, cfg, state, challenge) do
      {:ok, %{auth_url: auth_url, state: state, code_verifier: verifier}}
    end
  end

  @doc """
  Handle OAuth2 callback and exchange authorization code for tokens.

  Validates state, extracts code, exchanges for tokens with PKCE verifier.

  Returns: `{:ok, tokens}` with normalized token map
  """
  @spec handle_callback(config, map(), String.t(), String.t()) ::
          {:ok, tokens} | {:error, term()}
  def handle_callback(cfg, params, expected_state, code_verifier) do
    with {:ok, metadata} <- fetch_metadata(cfg.discovery_url),
         :ok <- verify_state(params, expected_state),
         {:ok, code} <- extract_code(params),
         {:ok, tokens} <- exchange_code(metadata, cfg, code, code_verifier) do
      {:ok, normalize_tokens(tokens)}
    end
  end

  @doc """
  Refresh an expired access token using the refresh token.

  Returns: `{:ok, tokens}` with new access token and possibly new refresh token
  """
  @spec refresh_token(config, String.t()) :: {:ok, tokens} | {:error, term()}
  def refresh_token(cfg, refresh_token) do
    with {:ok, metadata} <- fetch_metadata(cfg.discovery_url),
         {:ok, tokens} <- refresh_with_server(metadata, cfg, refresh_token) do
      {:ok, normalize_tokens(tokens)}
    end
  end

  # -- Metadata Discovery --

  defp fetch_metadata(discovery_url) do
    case HTTPoison.get(discovery_url, [], recv_timeout: 10_000, timeout: 10_000) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, metadata} when is_map(metadata) ->
            validate_metadata(metadata)

          {:ok, _} ->
            {:error, {:invalid_metadata, "Discovery response is not a JSON object"}}

          {:error, reason} ->
            {:error, {:invalid_json, reason}}
        end

      {:ok, %{status_code: code}} ->
        {:error, {:http_error, code}}

      {:error, reason} ->
        {:error, {:network_error, reason}}
    end
  end

  defp validate_metadata(metadata) do
    required = ["authorization_endpoint", "token_endpoint"]

    case Enum.filter(required, &(!Map.has_key?(metadata, &1))) do
      [] -> {:ok, metadata}
      missing -> {:error, {:incomplete_metadata, "Missing: #{Enum.join(missing, ", ")}"}}
    end
  end

  # -- PKCE Generation --

  defp generate_pkce do
    # Generate 32-byte random verifier, base64url encode
    verifier =
      :crypto.strong_rand_bytes(32)
      |> Base.url_encode64(padding: false)

    # SHA256 hash the verifier, base64url encode for challenge
    challenge =
      :crypto.hash(:sha256, verifier)
      |> Base.url_encode64(padding: false)

    {:ok, verifier, challenge}
  end

  defp generate_state do
    state =
      :crypto.strong_rand_bytes(16)
      |> Base.url_encode64(padding: false)

    {:ok, state}
  end

  # -- Authorization URL Building --

  defp build_authorization_url(metadata, cfg, state, challenge) do
    auth_endpoint = metadata["authorization_endpoint"]

    params = %{
      "response_type" => "code",
      "client_id" => cfg.client_id,
      "redirect_uri" => cfg.redirect_uri,
      "scope" => Enum.join(cfg.scopes, " "),
      "state" => state,
      "code_challenge" => challenge,
      "code_challenge_method" => "S256"
    }

    query = URI.encode_query(params)
    {:ok, "#{auth_endpoint}?#{query}"}
  end

  # -- State Verification --

  defp verify_state(params, expected_state) do
    case Map.get(params, "state") do
      ^expected_state -> :ok
      nil -> {:error, :missing_state}
      _ -> {:error, :state_mismatch}
    end
  end

  defp extract_code(params) do
    case Map.get(params, "code") do
      nil -> {:error, :missing_code}
      code when is_binary(code) -> {:ok, code}
      _ -> {:error, :invalid_code}
    end
  end

  # -- Token Exchange --

  defp exchange_code(metadata, cfg, code, code_verifier) do
    token_endpoint = metadata["token_endpoint"]

    body_params = %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => cfg.redirect_uri,
      "client_id" => cfg.client_id,
      "code_verifier" => code_verifier
    }

    # Add client_secret if provided (confidential client)
    body_params =
      if cfg[:client_secret] do
        Map.put(body_params, "client_secret", cfg.client_secret)
      else
        body_params
      end

    make_token_request(token_endpoint, body_params)
  end

  # -- Token Refresh --

  defp refresh_with_server(metadata, cfg, refresh_token) do
    token_endpoint = metadata["token_endpoint"]

    body_params = %{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh_token,
      "client_id" => cfg.client_id
    }

    # Add client_secret if provided
    body_params =
      if cfg[:client_secret] do
        Map.put(body_params, "client_secret", cfg.client_secret)
      else
        body_params
      end

    make_token_request(token_endpoint, body_params)
  end

  # -- HTTP Request Helper --

  defp make_token_request(token_endpoint, body_params) do
    headers = [
      {"Content-Type", "application/x-www-form-urlencoded"},
      {"Accept", "application/json"}
    ]

    body = URI.encode_query(body_params)

    case HTTPoison.post(token_endpoint, body, headers, recv_timeout: 15_000, timeout: 15_000) do
      {:ok, %{status_code: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, tokens} when is_map(tokens) ->
            {:ok, tokens}

          {:ok, _} ->
            {:error, {:invalid_response, "Token response is not a JSON object"}}

          {:error, reason} ->
            {:error, {:invalid_json, reason}}
        end

      {:ok, %{status_code: code, body: _error_body}} ->
        {:error, {:http_error, code}}

      {:error, reason} ->
        {:error, {:network_error, reason}}
    end
  end

  # -- Token Normalization --

  defp normalize_tokens(tokens) do
    # Calculate expires_at from expires_in (seconds from now)
    expires_at =
      case Map.get(tokens, "expires_in") do
        nil -> nil
        seconds when is_integer(seconds) -> System.system_time(:second) + seconds
        _ -> nil
      end

    %{
      access_token: Map.fetch!(tokens, "access_token"),
      token_type: Map.get(tokens, "token_type", "Bearer"),
      expires_at: expires_at,
      refresh_token: Map.get(tokens, "refresh_token"),
      scope: Map.get(tokens, "scope")
    }
  end
end

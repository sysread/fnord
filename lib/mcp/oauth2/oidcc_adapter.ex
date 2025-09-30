defmodule MCP.OAuth2.OidccAdapter do
  @moduledoc """
  Thin wrapper over oidcc for Discovery + PKCE + Authorization-Code + Refresh.
  MVP scope: no ID token validation.
  """

  require Record

  # Import Oidcc Token records for ergonomic access in Elixir
  Record.defrecord(
    :oidcc_token,
    Record.extract(:oidcc_token, from_lib: "oidcc/include/oidcc_token.hrl")
  )

  Record.defrecord(
    :oidcc_token_access,
    Record.extract(:oidcc_token_access, from_lib: "oidcc/include/oidcc_token.hrl")
  )

  Record.defrecord(
    :oidcc_token_refresh,
    Record.extract(:oidcc_token_refresh, from_lib: "oidcc/include/oidcc_token.hrl")
  )

  @type cfg :: %{
          required(:discovery_url) => String.t(),
          required(:client_id) => String.t(),
          optional(:client_secret) => String.t(),
          required(:redirect_uri) => String.t(),
          required(:scopes) => [String.t()]
        }

  @doc """
  Start OIDC Authorization Code + PKCE flow.
  Returns the authorization URL, opaque state, and PKCE code_verifier.
  """
  @spec start_flow(cfg) ::
          {:ok, %{auth_url: String.t(), state: String.t(), code_verifier: String.t()}}
          | {:error, term()}
  def start_flow(cfg) do
    with {:ok, issuer} <- fetch_issuer(cfg),
         {:ok, provider} <- start_provider_worker(issuer),
         {:ok, state} <- gen_state(),
         {:ok, {verifier, _challenge}} <- gen_pkce(),
         {:ok, auth_url} <-
           create_auth_url(provider, cfg, state, verifier) do
      {:ok, %{auth_url: auth_url, state: state, code_verifier: verifier}}
    else
      {:error, _} = e -> e
      e -> {:error, e}
    end
  end

  @doc """
  Handle the callback from the loopback route using the given params.
  `expected_state` and `code_verifier` must match what was returned from `start_flow/1`.
  Returns a normalized token map with `:access_token`, optional `:refresh_token`, `:token_type` (default "Bearer"), `:expires_at` (epoch seconds), and optional `:scope`.
  """
  @spec handle_callback(cfg, map(), String.t(), String.t()) ::
          {:ok,
           %{
             :access_token => String.t(),
             optional(:refresh_token) => String.t(),
             :token_type => String.t(),
             :expires_at => non_neg_integer(),
             optional(:scope) => String.t()
           }}
          | {:error, term()}
  def handle_callback(cfg, params, expected_state, code_verifier) do
    with :ok <- verify_state(params, expected_state),
         {:ok, code} <- fetch_code(params),
         {:ok, issuer} <- fetch_issuer(cfg),
         {:ok, provider} <- start_provider_worker(issuer),
         {:ok, token_rec} <- retrieve_token(provider, cfg, code, code_verifier) do
      normalize_token(token_rec)
    else
      {:error, _} = e -> e
      e -> {:error, e}
    end
  end

  @doc """
  Refresh an access token using the provided refresh token in `tokens`.
  Returns the same normalized token map as `handle_callback/4`.
  """
  @spec refresh_token(cfg, %{refresh_token: String.t()}) ::
          {:ok,
           %{
             :access_token => String.t(),
             optional(:refresh_token) => String.t(),
             :token_type => String.t(),
             :expires_at => non_neg_integer(),
             optional(:scope) => String.t()
           }}
          | {:error, term()}
  def refresh_token(cfg, %{refresh_token: refresh_token}) do
    with {:ok, issuer} <- fetch_issuer(cfg),
         {:ok, provider} <- start_provider_worker(issuer),
         {:ok, token_rec} <- refresh_with_provider(provider, cfg, refresh_token) do
      normalize_token(token_rec)
    else
      {:error, _} = e -> e
      e -> {:error, e}
    end
  end

  # -- internals --

  defp fetch_issuer(%{discovery_url: url}) when is_binary(url) do
    case HTTPoison.get(url, [], recv_timeout: 10_000, timeout: 10_000) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"issuer" => issuer}} when is_binary(issuer) -> {:ok, issuer}
          {:ok, _} -> {:error, :no_issuer_in_metadata}
          {:error, e} -> {:error, {:bad_metadata, e}}
        end

      {:ok, %{status_code: code}} ->
        {:error, {:http_error, code}}

      {:error, e} ->
        {:error, e}
    end
  end

  defp start_provider_worker(issuer) do
    case :oidcc_provider_configuration_worker.start_link(%{
           issuer: String.to_charlist(issuer)
         }) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  defp create_auth_url(provider, cfg, state, challenge) do
    client_id = to_bin(cfg.client_id)
    client_secret = cfg.client_secret || :unauthenticated

    client_secret =
      if client_secret == :unauthenticated, do: :unauthenticated, else: to_bin(client_secret)

    scopes = Enum.map(Map.get(cfg, :scopes, []), &to_bin/1)
    redirect_uri = to_bin(cfg.redirect_uri)

    opts = %{
      redirect_uri: redirect_uri,
      scopes: scopes,
      state: to_bin(state),
      # High-level interface expects pkce_verifier/require_pkce (see oidcc_authorization:opts)
      pkce_verifier: to_bin(challenge),
      require_pkce: true
    }

    case :oidcc.create_redirect_url(provider, client_id, client_secret, opts) do
      {:ok, uri} -> {:ok, to_elixir_bin(uri)}
      {:error, e} -> {:error, e}
    end
  end

  defp retrieve_token(provider, cfg, code, code_verifier) do
    client_id = to_bin(cfg.client_id)
    client_secret = cfg.client_secret || :unauthenticated

    client_secret =
      if client_secret == :unauthenticated, do: :unauthenticated, else: to_bin(client_secret)

    redirect_uri = to_bin(cfg.redirect_uri)
    scopes = Enum.map(Map.get(cfg, :scopes, []), &to_bin/1)

    opts = %{
      redirect_uri: redirect_uri,
      pkce_verifier: to_bin(code_verifier),
      require_pkce: true,
      scope: scopes
    }

    case :oidcc.retrieve_token(to_bin(code), provider, client_id, client_secret, opts) do
      {:ok, token_rec} -> {:ok, token_rec}
      {:error, e} -> {:error, e}
    end
  end

  defp refresh_with_provider(provider, cfg, refresh_token) do
    client_id = to_bin(cfg.client_id)
    client_secret = cfg.client_secret || :unauthenticated

    client_secret =
      if client_secret == :unauthenticated, do: :unauthenticated, else: to_bin(client_secret)

    scopes = Enum.map(Map.get(cfg, :scopes, []), &to_bin/1)

    opts = %{scope: scopes}

    case :oidcc.refresh_token(to_bin(refresh_token), provider, client_id, client_secret, opts) do
      {:ok, token_rec} -> {:ok, token_rec}
      {:error, e} -> {:error, e}
    end
  end

  defp normalize_token(token_rec) do
    access_rec = oidcc_token(token_rec, :access)

    cond do
      access_rec == :none ->
        {:error, :no_access_token}

      true ->
        access_token = oidcc_token_access(access_rec, :token) |> to_elixir_bin()

        token_type =
          case oidcc_token_access(access_rec, :type) |> to_elixir_bin() do
            "" -> "Bearer"
            v -> v
          end

        expires_in = oidcc_token_access(access_rec, :expires)
        now = System.os_time(:second)

        expires_at =
          case expires_in do
            i when is_integer(i) and i >= 0 -> now + i
            _ -> now + 3600
          end

        refresh_rec = oidcc_token(token_rec, :refresh)

        refresh_token =
          if refresh_rec == :none,
            do: nil,
            else: oidcc_token_refresh(refresh_rec, :token) |> to_elixir_bin()

        scopes = oidcc_token(token_rec, :scope)

        scope =
          scopes
          |> Enum.map(&to_elixir_bin/1)
          |> Enum.join(" ")

        {:ok,
         %{
           access_token: access_token,
           refresh_token: refresh_token,
           token_type: token_type,
           expires_at: expires_at,
           scope: scope
         }}
    end
  end

  defp verify_state(params, expected) do
    received = Map.get(params, "state") || Map.get(params, :state)

    if is_binary(received) and Plug.Crypto.secure_compare(received, expected) do
      :ok
    else
      {:error, :state_mismatch}
    end
  end

  defp fetch_code(params) do
    case Map.get(params, "code") || Map.get(params, :code) do
      code when is_binary(code) -> {:ok, code}
      _ -> {:error, :no_code}
    end
  end

  defp gen_state do
    {:ok, Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)}
  end

  defp gen_pkce do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(64), padding: false)

    challenge =
      :crypto.hash(:sha256, verifier)
      |> Base.url_encode64(padding: false)

    {:ok, {verifier, challenge}}
  end

  defp to_bin(v) when is_binary(v), do: v |> :erlang.iolist_to_binary()
  defp to_bin(v) when is_list(v), do: to_string(v) |> :erlang.iolist_to_binary()
  defp to_bin(v) when is_atom(v), do: Atom.to_string(v) |> :erlang.iolist_to_binary()

  defp to_elixir_bin(v) when is_binary(v), do: v
  defp to_elixir_bin(v) when is_list(v), do: List.to_string(v)
  defp to_elixir_bin(v) when is_atom(v), do: Atom.to_string(v)
end

defmodule MCP.OAuth2.Bridge do
  @moduledoc """
  Builds Authorization header for MCP transports.
  If token is near expiry, attempts a refresh via `Client` and persists.
  """

  alias MCP.OAuth2.{CredentialsStore, Client}

  @default_refresh_margin 120

  @spec authorization_header(String.t(), map(), keyword()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def authorization_header(server, cfg, opts \\ []) do
    margin = Keyword.get(opts, :refresh_margin, @default_refresh_margin)

    with {:ok, toks} <- CredentialsStore.read(server),
         {:ok, toks2} <- maybe_refresh(server, cfg, toks, margin),
         at when is_binary(at) <- Map.get(toks2, "access_token") do
      {:ok, [{"authorization", "Bearer " <> at}]}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :no_credentials}
    end
  end

  defp maybe_refresh(server, cfg, %{"expires_at" => exp} = toks, margin) do
    if exp - System.os_time(:second) <= margin do
      refresh(server, cfg, toks)
    else
      {:ok, toks}
    end
  end

  defp maybe_refresh(_server, _cfg, toks, _margin), do: {:ok, toks}

  defp refresh(server, cfg, %{"refresh_token" => rt}) when is_binary(rt) and rt != "" do
    # Build OAuth config for refresh - need discovery_url, client_id, optional client_secret
    oauth_cfg = %{
      discovery_url: Map.get(cfg["oauth"], "discovery_url"),
      client_id: Map.get(cfg["oauth"], "client_id"),
      client_secret: Map.get(cfg["oauth"], "client_secret"),
      scopes: Map.get(cfg["oauth"], "scopes", []),
      redirect_uri: "http://127.0.0.1/callback"
    }

    case Client.refresh_token(oauth_cfg, rt) do
      {:ok, new} ->
        :ok = CredentialsStore.write(server, normalize(new))
        {:ok, normalize(new)}

      {:error, e} ->
        {:error, e}
    end
  end

  defp refresh(_server, _cfg, _toks), do: {:error, :no_refresh_token}

  defp normalize(%{
         access_token: at,
         refresh_token: rt,
         token_type: tt,
         expires_at: exp,
         scope: sc
       }) do
    %{
      "access_token" => at,
      "refresh_token" => rt,
      "token_type" => tt,
      "expires_at" => exp,
      "scope" => sc
    }
  end
end

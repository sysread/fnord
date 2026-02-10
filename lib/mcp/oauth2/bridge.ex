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

  defp maybe_refresh(server, cfg, %{"expires_at" => exp} = toks, margin) when is_integer(exp) do
    if exp - System.os_time(:second) <= margin do
      refresh(server, cfg, toks)
    else
      {:ok, toks}
    end
  end

  # If expires_at is missing or not an integer, do not attempt arithmetic - treat as no refresh needed here
  defp maybe_refresh(_server, _cfg, toks, _margin), do: {:ok, toks}

  defp refresh(server, cfg, %{"refresh_token" => rt}) when is_binary(rt) and rt != "" do
    oauth = Map.get(cfg, "oauth", %{})

    # Use configured redirect_uri, or build from redirect_port, or omit if neither present
    redirect_uri =
      cond do
        is_binary(oauth["redirect_uri"]) ->
          oauth["redirect_uri"]

        is_integer(oauth["redirect_port"]) and oauth["redirect_port"] > 0 ->
          "http://localhost:#{oauth["redirect_port"]}/callback"

        true ->
          nil
      end

    # Build OAuth config for refresh - need discovery_url, client_id, optional client_secret
    oauth_cfg =
      %{
        discovery_url: oauth["discovery_url"],
        client_id: oauth["client_id"],
        client_secret: oauth["client_secret"],
        scopes: Map.get(oauth, "scopes", [])
      }
      |> maybe_put_redirect(redirect_uri)

    case Client.refresh_token(oauth_cfg, rt) do
      {:ok, new} ->
        :ok = CredentialsStore.write(server, normalize(new))
        {:ok, normalize(new)}

      {:error, e} ->
        {:error, e}
    end
  end

  defp refresh(_server, _cfg, _toks), do: {:error, :no_refresh_token}

  defp maybe_put_redirect(map, nil), do: map
  defp maybe_put_redirect(map, uri), do: Map.put(map, :redirect_uri, uri)

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

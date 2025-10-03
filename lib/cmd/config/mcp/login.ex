defmodule Cmd.Config.MCP.Login do
  @moduledoc """
  MCP OAuth2 login entrypoint under the config namespace.

  Performs the Authorization Code + PKCE flow using the configured adapter,
  opens the authorization URL in a browser, awaits the loopback callback, and
  persists tokens in the credentials store.
  """

  @spec run(map(), list(), list()) :: :ok
  def run(opts, [:mcp, :login], [server]) when is_binary(server) do
    if opts[:project], do: Settings.set_project(opts[:project])

    settings = Settings.new()
    cfgs = Settings.MCP.effective_config(settings)

    with {:ok, _srv_cfg} <- fetch_server(cfgs, server),
         {:ok, oauth} <- fetch_oauth(cfgs[server]),
         {:ok, port, state, verifier, auth_url, _redirect_uri} <-
           adapter().start_flow(oauth),
         :ok <- browser().open(auth_url),
         {:ok, token} <-
           await_callback(oauth, server, state, verifier, port, opts[:timeout] || 120_000) do
      UI.info("Auth", "Success for #{server}")
      print_tokens_redacted(token)
      # Brief delay to allow HTTP response to be sent to browser before process exits
      Process.sleep(3000)
      :ok
    else
      {:error, :not_found} ->
        UI.error("Server '#{server}' not found in config")

      {:error, {:oauth_missing, reason}} ->
        UI.error(reason)

      {:error, {:provider_rejected_redirect, uri}} ->
        UI.error("OAuth provider rejected redirect_uri", uri)

      {:error, :timeout} ->
        UI.error("Timed out waiting for authorization callback")

      {:error, e} ->
        UI.error("Auth error", inspect(e))
    end
  end

  defp fetch_server(cfgs, server) do
    case Map.fetch(cfgs, server) do
      {:ok, cfg} -> {:ok, cfg}
      :error -> {:error, :not_found}
    end
  end

  defp fetch_oauth(%{"oauth" => oauth}) when is_map(oauth) do
    with discovery when is_binary(discovery) <- Map.get(oauth, "discovery_url"),
         client_id when is_binary(client_id) <- Map.get(oauth, "client_id"),
         scopes when is_list(scopes) <- Map.get(oauth, "scopes") do
      oauth_map = %{
        discovery_url: discovery,
        client_id: client_id,
        client_secret: Map.get(oauth, "client_secret"),
        scopes: scopes
      }

      # Include redirect_port if present (for exact URI matching with OAuth provider)
      oauth_with_port =
        case Map.get(oauth, "redirect_port") do
          port when is_integer(port) -> Map.put(oauth_map, :redirect_port, port)
          _ -> oauth_map
        end

      {:ok, oauth_with_port}
    else
      _ ->
        {:error, {:oauth_missing, "OAuth config requires discovery_url, client_id, and scopes"}}
    end
  end

  defp fetch_oauth(_), do: {:error, {:oauth_missing, "No OAuth config for this server"}}

  defp await_callback(oauth, server, state, verifier, port, timeout_ms) do
    cfg = Map.put(oauth, :redirect_uri, "http://127.0.0.1:#{port}/callback")
    MCP.OAuth2.Loopback.run(cfg, server, state, verifier, port, timeout_ms)
  end

  defp print_tokens_redacted(token) do
    red = Map.take(token, ["token_type", "expires_at", "scope"]) |> Jason.encode!(pretty: true)
    UI.puts(red)
  end

  defp adapter, do: Application.get_env(:fnord, :mcp_oauth_adapter, MCP.OAuth2.Adapter.Default)
  defp browser, do: Application.get_env(:fnord, :browser, Browser.Default)
end

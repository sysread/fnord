defmodule Cmd.Config.MCP.Login do
  @moduledoc """
  MCP OAuth2 login entrypoint under the config namespace.

  Performs the Authorization Code + PKCE flow using the configured adapter,
  opens the authorization URL in a browser, awaits the loopback callback, and
  persists tokens in the credentials store.
  """

  @spec run(map(), list(), list()) :: :ok
  def run(opts, [:mcp, :login], [server]) when is_binary(server) do
    if opts[:project] do
      Settings.set_project(opts[:project])
    end

    settings = Settings.new()
    cfgs = Settings.MCP.effective_config(settings)

    with {:ok, srv_cfg} <- fetch_server(cfgs, server),
         {:ok, oauth} <- fetch_oauth(cfgs[server]),
         {:ok, port, state, verifier, auth_url, _redirect_uri} <-
           adapter().start_flow(oauth) do
      # Open browser for authentication
      UI.info("Opening browser for authentication...")

      case browser().open(auth_url) do
        :ok ->
          UI.info("Waiting for authorization callback...")

          case await_callback(
                 oauth,
                 srv_cfg["base_url"],
                 server,
                 state,
                 verifier,
                 port,
                 opts[:timeout] || 120_000
               ) do
            {:ok, _token} ->
              UI.info("Authentication successful!")

              # Brief delay to allow HTTP response to be sent to browser before process exits
              Process.sleep(3000)

              # Start MCP supervisor and check server status
              UI.info("Checking server status...")
              Services.MCP.start()
              Process.sleep(2000)

              UI.puts("")

              case Services.MCP.check_single_server(server) do
                {:ok, status} ->
                  Cmd.Config.MCP.CheckFormatter.format_results(status)

                {:error, :not_found} ->
                  # Fallback if server check fails (shouldn't happen)
                  UI.info("Authentication successful", server)
              end

              :ok

            {:error, reason} ->
              handle_auth_error(reason)
          end

        error ->
          handle_auth_error(error)
      end
    else
      {:error, :not_found} ->
        UI.error("Server not found in config", server)

      {:error, {:oauth_missing, reason}} ->
        UI.error("OAuth configuration error", reason)
    end
  end

  defp handle_auth_error(:timeout) do
    UI.error(
      "Timed out waiting for authorization callback",
      "The OAuth flow did not complete within the timeout period. Please try again."
    )
  end

  defp handle_auth_error({:provider_rejected_redirect, uri}) do
    UI.error("OAuth provider rejected redirect_uri", uri)
  end

  defp handle_auth_error({:network_error, %HTTPoison.Error{reason: :nxdomain}}) do
    UI.error(
      "No internet connection",
      "Unable to resolve DNS for OAuth provider. Check your network connection."
    )
  end

  defp handle_auth_error(error) do
    UI.error("Authentication error", inspect(error))
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

  defp await_callback(oauth, base_url, server, state, verifier, port, timeout_ms) do
    cfg = Map.put(oauth, :redirect_uri, "http://127.0.0.1:#{port}/callback")
    MCP.OAuth2.Loopback.run(cfg, base_url, server, state, verifier, port, timeout_ms)
  end

  defp adapter, do: Application.get_env(:fnord, :mcp_oauth_adapter, MCP.OAuth2.Adapter.Default)
  defp browser, do: Application.get_env(:fnord, :browser, Browser.Default)
end

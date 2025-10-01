defmodule Cmd.Mcp do
  @behaviour Cmd

  @impl Cmd
  def requires_project?(), do: false

  @impl Cmd
  def spec do
    [
      mcp: [
        name: "mcp",
        about: "MCP utilities",
        subcommands: [
          auth: [
            name: "auth",
            about: "Authenticate to an MCP server via OAuth2 (PKCE)",
            args: [
              server: [value_name: "SERVER", help: "Server name from config", required: true]
            ],
            options: [
              project: Cmd.project_arg(),
              timeout: [
                value_name: "MS",
                long: "--timeout",
                short: "-t",
                help: "Timeout for browser-based auth flow",
                parser: :integer,
                default: 120_000
              ]
            ]
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(opts, [:mcp, :auth], [server]) when is_binary(server) do
    if opts[:project], do: Settings.set_project(opts[:project])

    settings = Settings.new()
    cfgs = Settings.MCP.effective_config(settings)

    with {:ok, srv_cfg} <- fetch_server(cfgs, server),
         {:ok, oauth} <- fetch_oauth(srv_cfg),
         {:ok, port, state, verifier, auth_url, _redirect_uri} <-
           Application.get_env(:fnord, :mcp_oauth_adapter, MCP.OAuth2.Adapter.Default).start_flow(
             oauth
           ),
         :ok <- Application.get_env(:fnord, :browser, Browser.Default).open(auth_url),
         {:ok, token} <- await_callback(oauth, server, state, verifier, port, opts[:timeout]) do
      UI.info("Auth", "Success for #{server}")
      print_tokens_redacted(token)
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

  def run(_opts, _sub, _args) do
    UI.error("Unknown mcp subcommand")
  end

  # Helpers

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
      {:ok,
       %{
         discovery_url: discovery,
         client_id: client_id,
         client_secret: Map.get(oauth, "client_secret"),
         scopes: scopes
       }}
    else
      _ ->
        {:error, {:oauth_missing, "OAuth config requires discovery_url, client_id, and scopes"}}
    end
  end

  defp fetch_oauth(_), do: {:error, {:oauth_missing, "No OAuth config for this server"}}

  # Note: start_flow now resides in the injected MCP.OAuth2.Adapter module

  defp await_callback(oauth, server, state, verifier, port, timeout_ms) do
    cfg = Map.put(oauth, :redirect_uri, "http://127.0.0.1:#{port}/callback")
    MCP.OAuth2.Loopback.run(cfg, server, state, verifier, timeout_ms, port)
  end

  defp print_tokens_redacted(token) do
    red = Map.take(token, ["token_type", "expires_at", "scope"]) |> Jason.encode!(pretty: true)
    UI.puts(red)
  end
end

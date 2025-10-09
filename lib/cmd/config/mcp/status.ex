defmodule Cmd.Config.MCP.Status do
  @moduledoc """
  Show MCP OAuth token status for a server under the config namespace.
  """

  @spec run(map(), list(), list()) :: :ok
  def run(opts, [:mcp, :status], [server]) when is_binary(server) do
    if opts[:project] do
      Settings.set_project(opts[:project])
    end

    settings = Settings.new()
    cfgs = Settings.MCP.effective_config(settings)

    with {:ok, _srv_cfg} <- fetch_server(cfgs, server) do
      case MCP.OAuth2.CredentialsStore.read(server) do
        {:ok, %{"access_token" => _at, "expires_at" => exp} = m} ->
          now = System.os_time(:second)
          age = now - Map.get(m, "last_updated", now)
          UI.info("Token", "present")
          UI.info("Expires in", Integer.to_string(max(exp - now, 0)) <> "s")
          UI.info("Age", Integer.to_string(age) <> "s")

        {:error, :not_found} ->
          UI.warn("No credentials found for server", server)
      end
    else
      {:error, :not_found} -> UI.error("Server not found in config", server)
    end
  end

  defp fetch_server(cfgs, server) do
    case Map.fetch(cfgs, server) do
      {:ok, cfg} -> {:ok, cfg}
      :error -> {:error, :not_found}
    end
  end
end

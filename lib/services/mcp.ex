defmodule Services.MCP do
  @moduledoc false

  alias MCP.Supervisor, as: MCPSup
  alias Settings.MCP, as: MCPSettings
  alias Services.Once
  alias MCP.Tools
  alias UI

  @doc false
  defp client_mod, do: Application.get_env(:fnord, :mcp_client_mod, MCP.FnordClient)

  @spec start() :: :ok
  def start do
    cfg = MCPSettings.effective_config(Settings.new())

    if cfg["enabled"] && map_size(cfg["servers"]) > 0 do
      ensure_supervisor()
      Once.run(:mcp_discovery, fn -> discover_once(cfg["servers"]) end)
    end

    :ok
  end

  defp ensure_supervisor do
    case Process.whereis(MCPSup) do
      nil -> MCPSup.start_link([])
      _ -> :ok
    end

    :ok
  end

  defp discover_once(servers) when is_map(servers) do
    Enum.each(servers, fn {server, cfg} ->
      case safe_list_tools(server) do
        {:ok, tools} ->
          Tools.register_server_tools(server, tools)

        {:error, reason} ->
          UI.warn(
            Jason.encode!(
              %{
                mcp_discovery_error: %{server: server, transport: cfg["transport"], error: reason}
              },
              pretty: true
            )
          )
      end
    end)
  end

  defp safe_list_tools(server) do
    server
    |> MCPSup.instance_name()
    |> client_mod().list_tools()
  end

  @spec test() :: map()
  def test do
    cfg = MCPSettings.effective_config(Settings.new())

    servers =
      cfg["servers"]
      |> Enum.map(fn {server, _} ->
        info =
          case safe_get_info(server) do
            {:ok, _} -> %{status: "ok"}
            {:error, reason} -> %{status: "error", error: reason}
          end

        tools =
          case safe_list_tools(server) do
            {:ok, tools} ->
              %{status: "ok", tools: Enum.map(tools, &tool_blurb/1)}

            {:error, reason} ->
              %{status: "error", error: reason}
          end

        {server, Map.merge(info, tools)}
      end)
      |> Enum.into(%{})

    %{status: "ok", servers: servers}
  end

  defp tool_blurb(tool) do
    %{"name" => tool["name"], "description" => Map.get(tool, "description", "")}
  end

  defp safe_get_info(server) do
    server
    |> MCPSup.instance_name()
    |> client_mod().get_server_info()
  end
end

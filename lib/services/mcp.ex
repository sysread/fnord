defmodule Services.MCP do
  @moduledoc false

  alias MCP.Supervisor, as: MCPSup
  alias Settings.MCP, as: MCPSettings
  alias Services.Once
  alias MCP.Tools
  alias UI
  alias Hermes.Client.Base, as: MCPBase
  alias Hermes.MCP.Response
  alias Hermes.MCP.Error

  # Allow tests to override the client implementation via application env.
  # Default to Hermes.Client.Base (direct client API) in production.
  defp client_mod, do: Application.get_env(:fnord, :mcp_client_mod, MCPBase)

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

  # Robustly list tools for a server, supporting both Hermes.Base and stubbed return shapes.
  defp safe_list_tools(server) do
    instance = MCPSup.instance_name(server)

    case client_mod().list_tools(instance) do
      # Hermes.Base returns {:ok, Response.t()}
      {:ok, %Response{} = resp} ->
        result = Response.get_result(resp)
        tools = Map.get(result, "tools", [])
        {:ok, tools}

      # Some stubs might return {:ok, list}
      {:ok, tools} when is_list(tools) ->
        {:ok, tools}

      # Or {:ok, map} where map contains "tools"
      {:ok, %{"tools" => tools}} when is_list(tools) ->
        {:ok, tools}

      {:error, %Error{reason: reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
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

  # Retrieve server info; Hermes.Base returns a map or nil, stubs may return {:ok, map} | {:error, reason}
  defp safe_get_info(server) do
    instance = MCPSup.instance_name(server)

    case client_mod().get_server_info(instance) do
      # Hermes.Base shape
      %{} = info -> {:ok, info}
      nil -> {:error, :not_initialized}

      # Stubbed shapes
      {:ok, %{} = info} -> {:ok, info}
      {:error, %Error{reason: reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec tool_blurb(tool :: map()) :: map()
  defp tool_blurb(tool) do
    %{"name" => tool["name"], "description" => Map.get(tool, "description", "")}  
  end
end

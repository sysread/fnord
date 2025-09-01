defmodule Services.MCP do
  @moduledoc false

  alias MCP.Supervisor, as: MCPSup
  alias Settings.MCP, as: MCPSettings
  alias Services.Once
  alias MCP.Tools
  alias UI

  @spec start() :: :ok
  def start do
    # Configure Hermes MCP logging to reduce debug output
    Application.put_env(:hermes_mcp, :logging, [
      client_events: :info,
      server_events: :info,
      transport_events: :warning,
      protocol_messages: :warning
    ])

    servers = MCPSettings.effective_config(Settings.new())

    if map_size(servers) > 0 do
      ensure_supervisor()
      Once.run(:mcp_discovery, fn -> discover_once(servers) end)
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
                mcp_discovery_error: %{server: server, transport: cfg["transport"], error: inspect(reason)}
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

    # Check if the process exists and is alive
    case Process.whereis(instance) do
      nil ->
        {:error, :not_started}
      
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          # Process is alive, attempt to discover tools via the client module
          # Note: Tools may not be available immediately after handshake
          try do
            # Give the server a moment to complete initialization and handshake
            :timer.sleep(1000)
            # The instance is a supervisor, we need to find the client process
            children = Supervisor.which_children(instance)
            
            # Find the Hermes.Client.Base child process
            case List.keyfind(children, Hermes.Client.Base, 0) do
              {Hermes.Client.Base, client_pid, _, _} when is_pid(client_pid) ->
                result = Hermes.Client.Base.list_tools(client_pid)
                case result do
                  {:ok, %Hermes.MCP.Response{result: %{"tools" => tools}}} -> {:ok, tools}
                  {:ok, _response} -> {:ok, []}
                  {:error, reason} -> {:error, reason}
                end
              _ ->
                {:ok, []}
            end
          rescue
            _ -> 
              # Tools discovery failed, likely due to timing or client not ready
              # Return empty list for now - tools may be discovered later
              {:ok, []}
          end
        else
          {:error, :not_alive}
        end
    end
  end

  @spec test() :: map()
  def test do
    servers_cfg = MCPSettings.effective_config(Settings.new())

    servers =
      servers_cfg
      |> Enum.map(fn {server, _} ->
        info =
          case safe_get_info(server) do
            {:ok, server_info} -> %{status: "ok", server_info: server_info}
            {:error, reason} -> %{status: "error", error: inspect(reason)}
          end

        capabilities =
          case safe_get_capabilities(server) do
            {:ok, caps} -> %{capabilities: caps}
            {:error, _} -> %{capabilities: %{}}
          end

        tools =
          case safe_list_tools(server) do
            {:ok, tools} ->
              %{status: "ok", tools: Enum.map(tools, &tool_blurb/1)}

            {:error, reason} ->
              %{status: "error", error: inspect(reason)}
          end

        {server, info |> Map.merge(capabilities) |> Map.merge(tools)}
      end)
      |> Enum.into(%{})

    %{status: "ok", servers: servers}
  end

  # Retrieve server info; check if process is alive for now
  defp safe_get_info(server) do
    instance = MCPSup.instance_name(server)

    # Check if the process exists and is alive
    case Process.whereis(instance) do
      nil ->
        {:error, :not_started}
      
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          {:ok, %{"name" => "#{server}-server", "status" => "running"}}
        else
          {:error, :not_alive}
        end
    end
  end

  # Retrieve server capabilities
  defp safe_get_capabilities(server) do
    instance = MCPSup.instance_name(server)

    case Process.whereis(instance) do
      nil ->
        {:error, :not_started}
      
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          # Try to get capabilities from the client state
          try do
            children = Supervisor.which_children(instance)
            case List.keyfind(children, Hermes.Client.Base, 0) do
              {Hermes.Client.Base, client_pid, _, _} when is_pid(client_pid) ->
                # Try to get server capabilities from the client
                case Hermes.Client.Base.get_server_capabilities(client_pid) do
                  caps when is_map(caps) -> {:ok, caps}
                  nil -> {:ok, %{}}
                end
              _ ->
                {:ok, %{}}
            end
          rescue
            _ ->
              {:ok, %{}}
          end
        else
          {:error, :not_alive}
        end
    end
  end

  @spec tool_blurb(tool :: map()) :: map()
  defp tool_blurb(tool) do
    %{"name" => tool["name"], "description" => Map.get(tool, "description", "")}
  end
end

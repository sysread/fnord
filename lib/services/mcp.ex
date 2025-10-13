defmodule Services.MCP do
  @moduledoc false

  alias MCP.Supervisor, as: MCPSup
  alias Settings.MCP, as: MCPSettings
  alias Services.Once
  alias MCP.Tools
  alias UI

  @spec start(String.t() | atom() | nil) :: :ok
  def start(command \\ nil) do
    # Configure Hermes MCP logging - only show debug output when FNORD_DEBUG_MCP=1
    log_level =
      if System.get_env("FNORD_DEBUG_MCP") == "1" do
        :debug
      else
        :error
      end

    Application.put_env(:hermes_mcp, :logging,
      client_events: log_level,
      server_events: log_level,
      transport_events: log_level,
      protocol_messages: log_level
    )

    # Skip MCP discovery for config commands to avoid premature connection attempts
    # Users should be able to configure OAuth without triggering server connections
    skip_discovery = command in [:config, "config"]

    servers = MCPSettings.effective_config(Settings.new())

    if map_size(servers) > 0 && !skip_discovery do
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
    Enum.each(servers, fn {server, _cfg} ->
      case safe_list_tools(server) do
        {:ok, tools} ->
          Tools.register_server_tools(server, tools)

        {:error, _reason} ->
          # Silently skip failed servers during normal operation
          # Users should run 'fnord config mcp check' to diagnose issues
          :ok
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
            # Use a safe call that handles exits
            case safe_supervisor_call(instance) do
              {:ok, children} ->
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
                    {:error, :client_not_found}
                end

              {:error, reason} ->
                {:error, reason}
            end
          rescue
            error ->
              # Tools discovery failed, likely due to timing or client not ready
              {:error, {:rescue, error}}
          catch
            :exit, reason ->
              {:error, {:exit, reason}}
          end
        else
          {:error, :not_alive}
        end
    end
  end

  defp safe_supervisor_call(instance) do
    try do
      children = Supervisor.which_children(instance)
      {:ok, children}
    catch
      :exit, reason -> {:error, {:supervisor_call_failed, reason}}
    end
  end

  @spec test(keyword()) :: map()
  def test(opts \\ []) do
    settings = Settings.new()
    servers_cfg = MCPSettings.effective_config(settings)
    with_discovery = Keyword.get(opts, :with_discovery, false)

    servers =
      servers_cfg
      |> Enum.map(fn {server, cfg} ->
        {server, check_server_status(server, cfg, settings, with_discovery)}
      end)
      |> Enum.into(%{})

    %{status: "ok", servers: servers}
  end

  @doc """
  Checks the status of a single MCP server by name.
  Returns the same structure as a single server entry in test/1.
  """
  @spec check_single_server(String.t()) :: {:ok, map()} | {:error, :not_found}
  def check_single_server(server_name) when is_binary(server_name) do
    settings = Settings.new()
    servers_cfg = MCPSettings.effective_config(settings)

    case Map.fetch(servers_cfg, server_name) do
      {:ok, cfg} ->
        server_data = check_server_status(server_name, cfg, settings, false)
        {:ok, %{status: "ok", servers: %{server_name => server_data}}}

      :error ->
        {:error, :not_found}
    end
  end

  defp check_server_status(server, cfg, settings, with_discovery) do
    info =
      case safe_get_info(server) do
        {:ok, server_info} ->
          %{status: "ok", server_info: server_info}

        {:error, reason} ->
          # If discovery enabled and this is an HTTP server without mcp_path
          if with_discovery && should_attempt_discovery?(cfg) do
            attempt_discovery_for_server(server, cfg, settings)
          end

          %{status: "error", error: inspect(reason)}
      end

    capabilities =
      case safe_get_capabilities(server) do
        {:ok, caps} -> %{capabilities: caps}
        {:error, _} -> %{capabilities: %{}}
      end

    tools =
      case safe_list_tools(server) do
        {:ok, tools} ->
          %{tools: Enum.map(tools, &tool_blurb/1)}

        {:error, reason} ->
          %{error: inspect(reason)}
      end

    # Check authentication status
    auth_info = check_auth_status(server, cfg)

    info |> Map.merge(capabilities) |> Map.merge(tools) |> Map.merge(auth_info)
  end

  defp should_attempt_discovery?(cfg) do
    cfg["transport"] == "http" && !Map.has_key?(cfg, "mcp_path")
  end

  defp attempt_discovery_for_server(server, cfg, settings) do
    base_url = cfg["base_url"]

    case MCP.EndpointDiscovery.discover(base_url, ["/mcp", "/", "/api/mcp", "/mcp/v1"],
           server: server,
           config: cfg
         ) do
      {:ok, path} ->
        # Determine scope (global vs project)
        scope = determine_server_scope(server, settings)
        MCP.EndpointDiscovery.prompt_and_save(server, path, scope)

      {:error, :no_working_path} ->
        UI.error(
          "Could not find working MCP endpoint for '#{server}'",
          """
          Base URL: #{base_url}
          Paths tried: /mcp, /, /api/mcp, /mcp/v1

          To fix, manually set mcp_path in settings.json or use --mcp-path flag
          """
        )
    end
  end

  defp determine_server_scope(server, settings) do
    # Check if server is in project settings
    case Settings.get_selected_project() do
      {:ok, project_name} ->
        # Check if this server is defined in project scope
        case Settings.get_project_data(settings, project_name) do
          nil ->
            :global

          project_data ->
            project_servers = Map.get(project_data, "mcp_servers", %{})

            if Map.has_key?(project_servers, server) do
              {:project, project_name}
            else
              :global
            end
        end

      {:error, _} ->
        :global
    end
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
            case safe_supervisor_call(instance) do
              {:ok, children} ->
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

              {:error, _} ->
                {:ok, %{}}
            end
          rescue
            _ ->
              {:ok, %{}}
          catch
            :exit, _ ->
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

  @spec check_auth_status(String.t(), map()) :: map()
  defp check_auth_status(server, cfg) do
    has_oauth = Map.has_key?(cfg, "oauth") && is_map(cfg["oauth"])

    if has_oauth do
      auth_status =
        case MCP.OAuth2.CredentialsStore.read(server) do
          {:ok, %{"expires_at" => exp}} when is_integer(exp) ->
            now = System.os_time(:second)

            if exp > now do
              :valid
            else
              :expired
            end

          {:ok, _} ->
            # Has credentials but no expires_at - consider valid
            :valid

          {:error, :not_found} ->
            :missing
        end

      %{has_oauth: true, auth_status: auth_status}
    else
      %{has_oauth: false}
    end
  end
end

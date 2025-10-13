defmodule Cmd.Config.MCP do
  @moduledoc """
  Aggregator for MCP commands. Directly handles list, check, add, update, and remove operations,
  and delegates login and status commands to specialized submodules.
  """
  alias Cmd.Config.Utils

  @spec run(map(), list(), list()) :: :ok
  def run(opts, [:mcp, :list], _unknown) do
    settings = Settings.new()

    cond do
      opts[:effective] ->
        Settings.MCP.effective_config(settings)
        |> Jason.encode!(pretty: true)
        |> UI.puts()

      opts[:global] ->
        Settings.MCP.get_config(settings, :global)
        |> Jason.encode!(pretty: true)
        |> UI.puts()

      # project scope explicitly via --project
      opts[:project] ->
        # verify project configuration exists in settings
        case Settings.get_project_data(settings, opts[:project]) do
          nil ->
            UI.error("Project not specified or not found")

          _proj_data ->
            # activate project context and print config
            Settings.set_project(opts[:project])

            Settings.MCP.get_config(settings, :project)
            |> Jason.encode!(pretty: true)
            |> UI.puts()
        end

      # default to current project in settings
      true ->
        case Settings.get_selected_project() do
          {:ok, _proj} ->
            Settings.MCP.get_config(settings, :project)
            |> Jason.encode!(pretty: true)
            |> UI.puts()

          {:error, _} ->
            UI.error("Project not specified or not found")
        end
    end
  end

  def run(opts, [:mcp, :check], _unknown) do
    if opts[:project] do
      Settings.set_project(opts[:project])
    end

    Services.MCP.start()

    Services.MCP.test(with_discovery: true)
    |> Cmd.Config.MCP.CheckFormatter.format_results()
  end

  # Unified entry for add, update, remove
  def run(opts, [:mcp, action], args) when action in [:add, :update, :remove] do
    if opts[:project] do
      Settings.set_project(opts[:project])
    end

    case Utils.require_key(opts, args, :name, "Server name") do
      {:error, msg} ->
        UI.error(msg)

      {:ok, name} ->
        do_mcp_action(opts, action, name)
    end
  end

  # Delegate login and status to submodules
  def run(opts, [:mcp, :login], args) do
    case Utils.require_key(opts, args, :server, "Server name") do
      {:error, msg} ->
        UI.error(msg)

      {:ok, server} ->
        Cmd.Config.MCP.Login.run(opts, [:mcp, :login], [server])
    end
  end

  def run(opts, [:mcp, :status], args) do
    case Utils.require_key(opts, args, :server, "Server name") do
      {:error, msg} ->
        UI.error(msg)

      {:ok, server} ->
        Cmd.Config.MCP.Status.run(opts, [:mcp, :status], [server])
    end
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------
  @spec reserve_ephemeral_port() :: {:ok, non_neg_integer()}
  defp reserve_ephemeral_port do
    # Open a socket to get an ephemeral port, then close it
    # The port will remain available for immediate reuse
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, {:ip, {127, 0, 0, 1}}, {:active, false}, {:reuseaddr, true}])

    {:ok, {_addr, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    {:ok, port}
  end

  @spec build_server_config_from_opts(map()) :: map()
  defp build_server_config_from_opts(opts) do
    %{}
    |> maybe_put("transport", opts[:transport] || "stdio")
    |> maybe_put("command", opts[:command])
    |> maybe_put("args", opts[:arg] || [])
    |> maybe_put("base_url", opts[:url])
    |> maybe_put("mcp_path", opts[:mcp_path])
    |> maybe_put("headers", parse_kv_list(opts[:header] || []))
    |> maybe_put("env", parse_kv_list(opts[:env] || []))
    |> maybe_put("timeout_ms", opts[:timeout_ms])
  end

  @spec maybe_put(map(), String.t(), any()) :: map()
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @spec parse_kv_list(nil | [String.t()]) :: map()
  defp parse_kv_list(nil), do: %{}

  defp parse_kv_list(list) when is_list(list) do
    Enum.reduce(list, %{}, fn kv, acc ->
      case String.split(kv, "=", parts: 2) do
        [k, v] -> Map.put(acc, k, v)
        _ -> acc
      end
    end)
  end

  # Internal dispatcher for MCP add/update/remove actions
  defp do_mcp_action(opts, :add, name) do
    base_config = build_server_config_from_opts(opts)
    settings = Settings.new()

    scope =
      if opts[:global] do
        :global
      else
        :project
      end

    # If --oauth flag present, run auto-discovery and setup
    config_with_oauth =
      if opts[:oauth] do
        case opts[:url] do
          nil ->
            UI.error("--url is required when using --oauth")
            exit({:shutdown, 1})

          url ->
            # Reserve a port for the loopback callback first
            {:ok, port} = reserve_ephemeral_port()

            discovery_opts = [
              client_id: opts[:client_id],
              client_secret: opts[:client_secret],
              scope: opts[:scope],
              redirect_port: port
            ]

            case MCP.OAuth2.Discovery.discover_and_setup(url, discovery_opts) do
              {:ok, oauth_config} ->
                # oauth_config already includes redirect_port from discovery_opts
                Map.put(base_config, "oauth", oauth_config)

              {:error, :discovery_not_found} ->
                UI.error(
                  "OAuth discovery failed (404)",
                  """
                  Server does not support OAuth auto-discovery

                  Try: fnord config mcp add #{name} --url #{url} --client-id YOUR_CLIENT_ID
                  """
                )

                exit({:shutdown, 1})

              {:error, :no_registration_endpoint} ->
                UI.error(
                  "OAuth registration not available",
                  """
                  Server requires pre-registered client

                  Get a client_id from the provider, then:
                  fnord config mcp add #{name} --url #{url} --oauth --client-id YOUR_CLIENT_ID
                  """
                )

                exit({:shutdown, 1})

              {:error, {:incomplete_metadata, msg}} ->
                UI.error(
                  "Invalid discovery document",
                  """
                  #{msg}

                  Server OAuth configuration is incomplete. Contact server administrator.
                  """
                )

                exit({:shutdown, 1})

              {:error, reason} ->
                UI.error("OAuth setup failed", inspect(reason))
                exit({:shutdown, 1})
            end
        end
      else
        base_config
      end

    case Settings.MCP.add_server(settings, scope, name, config_with_oauth) do
      {:ok, upd} ->
        server_config = Settings.MCP.list_servers(upd, scope)[name]
        %{name => server_config} |> Jason.encode!(pretty: true) |> UI.puts()

        # If OAuth was configured, prompt user to login
        if opts[:oauth] do
          UI.puts("")
          UI.puts("  Ready for login: fnord config mcp login #{name}")
        end

      {:error, :exists} ->
        UI.error("Server already exists", name)

      {:error, err} ->
        UI.error("Add failed", inspect(err))
    end
  end

  defp do_mcp_action(opts, :update, name) do
    raw = build_server_config_from_opts(opts)
    settings = Settings.new()

    scope =
      if opts[:global] do
        :global
      else
        :project
      end

    case Settings.MCP.update_server(settings, scope, name, raw) do
      {:ok, upd} ->
        %{name => Settings.MCP.list_servers(upd, scope)[name]}
        |> Jason.encode!(pretty: true)
        |> UI.puts()

      {:error, :not_found} ->
        UI.error("Server not found", name)

      {:error, err} ->
        UI.error("Update failed", inspect(err))
    end
  end

  defp do_mcp_action(opts, :remove, name) do
    settings = Settings.new()

    scope =
      if opts[:global] do
        :global
      else
        :project
      end

    case Settings.MCP.remove_server(settings, scope, name) do
      {:ok, upd} ->
        Settings.MCP.list_servers(upd, scope)
        |> Jason.encode!(pretty: true)
        |> UI.puts()

      {:error, :not_found} ->
        UI.error("Server not found", name)
    end
  end
end

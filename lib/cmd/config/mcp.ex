defmodule Cmd.Config.MCP do
  @moduledoc false

  @spec run(map(), list(), list()) :: :ok
  def run(opts, [:mcp, :list], _unknown) do
    settings = Settings.new()

    cond do
      opts[:effective] ->
        Settings.MCP.effective_config(settings)
        |> Jason.encode!(pretty: true)
        |> IO.puts()

      opts[:global] ->
        Settings.MCP.get_config(settings, :global)
        |> Jason.encode!(pretty: true)
        |> IO.puts()

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
            |> IO.puts()
        end

      # default to current project in settings
      true ->
        case Settings.get_selected_project() do
          {:ok, _proj} ->
            Settings.MCP.get_config(settings, :project)
            |> Jason.encode!(pretty: true)
            |> IO.puts()

          {:error, _} ->
            UI.error("Project not specified or not found")
        end
    end
  end

  def run(opts, [:mcp, :enable], _unknown) do
    if opts[:project], do: Settings.set_project(opts[:project])
    settings = Settings.new()
    scope = if opts[:global], do: :global, else: :project
    updated = Settings.MCP.enable(settings, scope)

    Settings.MCP.get_config(updated, scope)
    |> Jason.encode!(pretty: true)
    |> IO.puts()
  end

  def run(opts, [:mcp, :disable], _unknown) do
    if opts[:project], do: Settings.set_project(opts[:project])
    settings = Settings.new()
    scope = if opts[:global], do: :global, else: :project
    updated = Settings.MCP.disable(settings, scope)

    Settings.MCP.get_config(updated, scope)
    |> Jason.encode!(pretty: true)
    |> IO.puts()
  end

  def run(opts, [:mcp, :add], [name]) do
    if opts[:project], do: Settings.set_project(opts[:project])
    raw_cfg = build_server_config_from_opts(opts)
    settings = Settings.new()
    scope = if opts[:global], do: :global, else: :project

    case Settings.MCP.add_server(settings, scope, name, raw_cfg) do
      {:ok, updated} ->
        scfg = Settings.MCP.list_servers(updated, scope)[name]

        %{name => scfg}
        |> Jason.encode!(pretty: true)
        |> IO.puts()

      {:error, :exists} ->
        UI.error("Server '#{name}' already exists")

      {:error, msg} ->
        UI.error(msg)
    end
  end

  def run(opts, [:mcp, :update], [name]) do
    if opts[:project], do: Settings.set_project(opts[:project])
    raw_cfg = build_server_config_from_opts(opts)
    settings = Settings.new()
    scope = if opts[:global], do: :global, else: :project

    case Settings.MCP.update_server(settings, scope, name, raw_cfg) do
      {:ok, updated} ->
        scfg = Settings.MCP.list_servers(updated, scope)[name]

        %{name => scfg}
        |> Jason.encode!(pretty: true)
        |> IO.puts()

      {:error, :not_found} ->
        UI.error("Server '#{name}' not found")

      {:error, msg} ->
        UI.error(msg)
    end
  end

  def run(opts, [:mcp, :remove], [name]) do
    if opts[:project], do: Settings.set_project(opts[:project])
    settings = Settings.new()
    scope = if opts[:global], do: :global, else: :project

    case Settings.MCP.remove_server(settings, scope, name) do
      {:ok, new_settings} ->
        Settings.MCP.list_servers(new_settings, scope)
        |> Jason.encode!(pretty: true)
        |> IO.puts()

      {:error, :not_found} ->
        UI.error("Server '#{name}' not found")
    end
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------
  @spec build_server_config_from_opts(map()) :: map()
  defp build_server_config_from_opts(opts) do
    %{}
    |> Map.put("transport", opts[:transport])
    |> maybe_put("command", opts[:command])
    |> maybe_put("args", opts[:arg] || [])
    |> maybe_put("base_url", opts[:base_url])
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
end

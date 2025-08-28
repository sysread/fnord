defmodule Settings.MCP do
  @moduledoc """
  Manage Hermes MCP server configuration under the "mcp_servers" key in settings.

  MCP configuration can be stored at both global and project scopes without
  being automatically written unless the user performs a configuration action.

  Configuration format:

  "mcp_servers": %{  
    "enabled" => boolean,
    "servers" => %{server_name => server_config}
  }

  server_config fields:
    - "transport": "stdio" | "streamable_http" | "websocket"
    - "timeout_ms": integer (optional)
    - stdio-specific:
      - "command": string
      - "args": [string]
      - "env": %{string => string}
    - http/ws-specific:
      - "base_url": string
      - "headers": %{string => string}
  """

  @typedoc "Underlying Settings struct"
  @type settings :: Settings.t()

  @typedoc "Scope of MCP configuration: global or project"
  @type scope :: :global | :project

  @typedoc "Configuration for an individual MCP server"
  @type server_config :: map()
  @typedoc "Full MCP configuration"
  @type config :: map()
  @doc "Retrieve MCP configuration for the given scope without writing defaults"
  @spec get_config(settings(), scope()) :: config()
  def get_config(settings, :global) do
    raw = Settings.get(settings, "mcp_servers", %{})
    normalize(raw)
  end

  def get_config(settings, :project) do
    case Settings.get_project(settings) do
      {:ok, project} ->
        normalize(Map.get(project, "mcp_servers", %{}))

      _ ->
        %{"enabled" => false, "servers" => %{}}
    end
  end

  @doc "Set MCP configuration for the given scope"
  @spec set_config(settings, scope, map()) :: settings
  def set_config(settings, :global, cfg) do
    Settings.set(settings, "mcp_servers", cfg)
  end

  def set_config(settings, :project, cfg) do
    case Settings.get_selected_project() do
      {:ok, project} ->
        existing = Settings.get_project_data(settings, project) || %{}
        updated = Map.put(existing, "mcp_servers", cfg)
        Settings.set_project_data(settings, project, updated)

      {:error, :project_not_set} ->
        settings
    end
  end

  # Fallback for unexpected scope
  def set_config(settings, _scope, _cfg), do: settings

  @doc "Return true if MCP is enabled in the given scope"
  @spec enabled?(settings, scope) :: boolean

  def enabled?(settings, scope), do: get_config(settings, scope)["enabled"]

  @doc "Enable MCP for the given scope"
  @spec enable(settings, scope) :: settings
  def enable(settings, scope) do
    cfg = get_config(settings, scope)
    set_config(settings, scope, Map.put(cfg, "enabled", true))
  end

  @doc "Disable MCP for the given scope"
  @spec disable(settings, scope) :: settings
  def disable(settings, scope) do
    cfg = get_config(settings, scope)
    set_config(settings, scope, Map.put(cfg, "enabled", false))
  end

  @doc "List configured MCP servers by name for the given scope"
  @spec list_servers(settings, scope) :: map()
  def list_servers(settings, scope), do: get_config(settings, scope)["servers"]

  @doc "Add a new MCP server configuration"
  @spec add_server(settings, scope, String.t(), map()) :: {:ok, settings} | {:error, any}
  def add_server(settings, scope, name, raw_cfg) do
    with {:ok, cfg} <- validate_server_config(raw_cfg),
         existing <- get_config(settings, scope)["servers"],
         false <- Map.has_key?(existing, name) do
      servers = Map.put(existing, name, cfg)
      enabled = get_config(settings, scope)["enabled"]
      new_cfg = %{"enabled" => enabled, "servers" => servers}
      {:ok, set_config(settings, scope, new_cfg)}
    else
      true -> {:error, :exists}
      {:error, msg} -> {:error, msg}
    end
  end

  @doc "Update an existing MCP server configuration"
  @spec update_server(settings, scope, String.t(), map()) :: {:ok, settings} | {:error, any}
  def update_server(settings, scope, name, raw_cfg) do
    with {:ok, cfg} <- validate_server_config(raw_cfg),
         existing <- get_config(settings, scope)["servers"],
         true <- Map.has_key?(existing, name) do
      servers = Map.put(existing, name, cfg)
      enabled = get_config(settings, scope)["enabled"]
      new_cfg = %{"enabled" => enabled, "servers" => servers}
      {:ok, set_config(settings, scope, new_cfg)}
    else
      false -> {:error, :not_found}
      {:error, msg} -> {:error, msg}
    end
  end

  @doc "Remove an existing MCP server configuration"
  @spec remove_server(settings, scope, String.t()) :: {:ok, settings} | {:error, any}
  def remove_server(settings, scope, name) do
    existing = get_config(settings, scope)["servers"]

    if Map.has_key?(existing, name) do
      servers = Map.delete(existing, name)
      enabled = get_config(settings, scope)["enabled"]
      new_cfg = %{"enabled" => enabled, "servers" => servers}
      {:ok, set_config(settings, scope, new_cfg)}
    else
      {:error, :not_found}
    end
  end

  @doc "Merge global and project MCP configurations, applying project overrides"
  @spec effective_config(settings()) :: config()
  def effective_config(settings) do
    g = get_config(settings, :global)
    p = get_config(settings, :project)

    %{
      "enabled" => p["enabled"] || g["enabled"],
      "servers" => Map.merge(g["servers"], p["servers"])
    }
  end

  # Normalize raw MCP configuration, ensuring expected shape
  defp normalize(%{"enabled" => enabled, "servers" => servers})
       when is_boolean(enabled) and is_map(servers) do
    %{"enabled" => enabled, "servers" => servers}
  end

  defp normalize(_), do: %{"enabled" => false, "servers" => %{}}

  @spec validate_server_config(map()) :: {:ok, map()} | {:error, String.t()}
  defp validate_server_config(%{"transport" => t} = cfg)
       when t in ["stdio", "streamable_http", "websocket"] do
    # Common optional field: timeout_ms
    cfg1 =
      case Map.get(cfg, "timeout_ms") do
        tm when is_integer(tm) and tm >= 0 -> Map.put(cfg, "timeout_ms", tm)
        _ -> Map.delete(cfg, "timeout_ms")
      end

    case t do
      "stdio" ->
        with command when is_binary(command) <- Map.get(cfg1, "command"),
             args <- Map.get(cfg1, "args", []),
             true <- is_list(args),
             env <- Map.get(cfg1, "env", %{}),
             true <- is_map(env) do
          normalized = %{
            "transport" => "stdio",
            "command" => command,
            "args" => args,
            "env" => env
          }

          normalized =
            if Map.has_key?(cfg1, "timeout_ms"),
              do: Map.put(normalized, "timeout_ms", cfg1["timeout_ms"]),
              else: normalized

          {:ok, normalized}
        else
          nil -> {:error, "Missing 'command' for stdio transport"}
          false -> {:error, "Invalid 'args' or 'env' for stdio transport"}
        end

      "streamable_http" ->
        with base_url when is_binary(base_url) <- Map.get(cfg1, "base_url"),
             headers <- Map.get(cfg1, "headers", %{}),
             true <- is_map(headers) do
          normalized = %{
            "transport" => "streamable_http",
            "base_url" => base_url,
            "headers" => headers
          }

          normalized =
            if Map.has_key?(cfg1, "timeout_ms"),
              do: Map.put(normalized, "timeout_ms", cfg1["timeout_ms"]),
              else: normalized

          {:ok, normalized}
        else
          nil -> {:error, "Missing 'base_url' for streamable_http transport"}
          false -> {:error, "Invalid 'headers' for streamable_http transport"}
        end

      "websocket" ->
        with base_url when is_binary(base_url) <- Map.get(cfg1, "base_url"),
             headers <- Map.get(cfg1, "headers", %{}),
             true <- is_map(headers) do
          normalized = %{
            "transport" => "websocket",
            "base_url" => base_url,
            "headers" => headers
          }

          normalized =
            if Map.has_key?(cfg1, "timeout_ms"),
              do: Map.put(normalized, "timeout_ms", cfg1["timeout_ms"]),
              else: normalized

          {:ok, normalized}
        else
          nil -> {:error, "Missing 'base_url' for websocket transport"}
          false -> {:error, "Invalid 'headers' for websocket transport"}
        end
    end
  end

  defp validate_server_config(_), do: {:error, "Missing or invalid 'transport' field"}
end

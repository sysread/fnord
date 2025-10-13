defmodule MCP.EndpointDiscovery do
  @moduledoc """
  Auto-discovers MCP endpoint paths when the default path returns 404.
  """

  require Logger

  @common_paths ["/mcp", "/", "/api/mcp", "/mcp/v1"]

  @doc """
  Attempts to discover the MCP endpoint path by trying common paths.
  Returns {:ok, path} if a working path is found, {:error, reason} otherwise.

  ## Options
    * `:server` - Server name for OAuth header lookup
    * `:config` - Server configuration map (for OAuth)
  """
  @spec discover(String.t(), list(String.t()), keyword()) :: {:ok, String.t()} | {:error, term()}
  def discover(base_url, paths \\ @common_paths, opts \\ []) do
    UI.info("MCP Discovery", "Endpoint not found, trying common paths...")

    # Build OAuth headers if server config provided
    headers = build_auth_headers(opts)

    results =
      Enum.map(paths, fn path ->
        url = Path.join(base_url, path)
        {path, check_endpoint(url, headers)}
      end)

    # Show results as we go
    Enum.each(results, fn {path, result} ->
      case result do
        {:ok, _} ->
          UI.info("  ✓ #{path}")

        {:error, status} when is_integer(status) ->
          UI.info("  ✗ #{path} (#{status})")

        {:error, _reason} ->
          UI.info("  ✗ #{path} (error)")
      end
    end)

    # Find first successful path
    case Enum.find(results, fn {_path, result} -> match?({:ok, _}, result) end) do
      {path, {:ok, _}} ->
        {:ok, path}

      nil ->
        {:error, :no_working_path}
    end
  end

  @doc """
  Prompts the user to save the discovered path to settings.
  Returns :ok if saved (or user declined), {:error, reason} on failure.
  """
  @spec prompt_and_save(String.t(), String.t(), :global | {:project, String.t()}) ::
          :ok | {:error, term()}
  def prompt_and_save(server_name, path, scope) do
    UI.newline()

    "Found MCP endpoint at #{path}. Save this to configuration? [Y/n] "
    |> UI.prompt()
    |> case do
      {:error, :no_tty} ->
        # Non-interactive mode, skip prompting
        UI.info(
          "Discovery",
          "Found endpoint at #{path} but cannot prompt in non-interactive mode"
        )

        UI.info("", "Manually add \"mcp_path\": \"#{path}\" to settings.json")
        :ok

      response ->
        response
        |> String.trim()
        |> String.downcase()
        |> case do
          "" ->
            save_discovered_path(server_name, path, scope)

          "y" ->
            save_discovered_path(server_name, path, scope)

          _ ->
            UI.info(
              "Discovery",
              "Path not saved. You can manually add it to settings.json later."
            )

            :ok
        end
    end
  end

  defp save_discovered_path(server_name, path, scope) do
    case save_to_settings(server_name, path, scope) do
      :ok ->
        UI.info("Discovery", "Saved mcp_path='#{path}' for server '#{server_name}'")
        UI.info("", "Restart fnord to use the new endpoint")
        :ok

      {:error, reason} ->
        UI.error("Failed to save MCP endpoint discovery", inspect(reason))
        {:error, reason}
    end
  end

  defp save_to_settings(server_name, path, scope) do
    # Read current settings file directly
    settings_path = Path.join(System.user_home!(), ".fnord/settings.json")

    with {:ok, content} <- File.read(settings_path),
         {:ok, settings_json} <- Jason.decode(content),
         {:ok, updated_json} <- update_mcp_path(settings_json, server_name, path, scope),
         {:ok, encoded} <- Jason.encode(updated_json, pretty: true),
         :ok <- File.write(settings_path, encoded) do
      :ok
    else
      error -> error
    end
  end

  defp update_mcp_path(settings, server_name, path, :global) do
    mcp_servers = Map.get(settings, "mcp_servers", %{})

    case Map.get(mcp_servers, server_name) do
      nil ->
        {:error, :server_not_found}

      server_cfg ->
        updated_server = Map.put(server_cfg, "mcp_path", path)
        updated_mcp = Map.put(mcp_servers, server_name, updated_server)
        {:ok, Map.put(settings, "mcp_servers", updated_mcp)}
    end
  end

  defp update_mcp_path(settings, server_name, path, {:project, project}) do
    projects = Map.get(settings, "projects", %{})
    project_cfg = Map.get(projects, project, %{})
    mcp_servers = Map.get(project_cfg, "mcp_servers", %{})

    case Map.get(mcp_servers, server_name) do
      nil ->
        {:error, :server_not_found}

      server_cfg ->
        updated_server = Map.put(server_cfg, "mcp_path", path)
        updated_mcp = Map.put(mcp_servers, server_name, updated_server)
        updated_project = Map.put(project_cfg, "mcp_servers", updated_mcp)
        updated_projects = Map.put(projects, project, updated_project)
        {:ok, Map.put(settings, "projects", updated_projects)}
    end
  end

  # Build authorization headers for OAuth-protected endpoints
  defp build_auth_headers(opts) do
    case {Keyword.get(opts, :server), Keyword.get(opts, :config)} do
      {nil, _} ->
        []

      {_server, nil} ->
        []

      {server, cfg} ->
        case MCP.OAuth2.Bridge.authorization_header(server, cfg) do
          {:ok, header_list} -> header_list
          {:error, _} -> []
        end
    end
  end

  # Check if endpoint exists using HEAD request, fallback to GET
  defp check_endpoint(url, headers) do
    # Try HEAD first
    case HTTPoison.head(url, headers, recv_timeout: 5_000, timeout: 5_000) do
      {:ok, %{status_code: status}} when status in 200..299 ->
        {:ok, status}

      # 400 = Bad Request, likely because MCP endpoint expects JSON-RPC POST, not HEAD
      # But it confirms the endpoint exists and auth worked (vs 401/403/404)
      {:ok, %{status_code: 400}} ->
        {:ok, 400}

      {:ok, %{status_code: 405}} ->
        # Method not allowed, try GET
        check_endpoint_with_get(url, headers)

      {:ok, %{status_code: status}} ->
        {:error, status}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_endpoint_with_get(url, headers) do
    case HTTPoison.get(url, headers, recv_timeout: 5_000, timeout: 5_000) do
      {:ok, %{status_code: status}} when status in 200..299 ->
        {:ok, status}

      # 400 = Bad Request, likely because MCP endpoint expects JSON-RPC POST
      # But it confirms the endpoint exists and auth worked
      {:ok, %{status_code: 400}} ->
        {:ok, 400}

      {:ok, %{status_code: status}} ->
        {:error, status}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

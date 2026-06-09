defmodule MCP.Transport do
  @moduledoc "Convert MCP server config into Hermes transport tuples and helpers for OAuth header injection"

  @typedoc "Hermes transport tuple"
  @type t ::
          {:stdio, keyword()}
          | {:streamable_http, keyword()}
          | {:websocket, keyword()}

  @doc "Convert server config map into a Hermes transport tuple"
  @spec map(String.t(), map()) :: {atom(), keyword()}
  def map(_server, %{"transport" => "stdio"} = cfg) do
    {:stdio,
     [
       command: MCP.STDIOWrapper.script_path!(),
       args: [cfg["command"] | cfg["args"] || []],
       env: cfg["env"] || %{}
     ]}
  end

  def map(server, %{"transport" => "http"} = cfg) do
    headers = merge_oauth_header(server, cfg, cfg["headers"] || %{})
    {base_url, mcp_path} = split_endpoint(cfg)

    {:streamable_http,
     [
       base_url: base_url,
       mcp_path: mcp_path,
       headers: headers
     ]}
  end

  def map(server, %{"transport" => "websocket"} = cfg) do
    headers = merge_oauth_header(server, cfg, cfg["headers"] || %{})

    {:websocket,
     [
       base_url: cfg["base_url"],
       headers: headers
     ]}
  end

  def map(server, %{"transport" => transport} = _cfg) do
    UI.error("""
    Invalid transport '#{transport}' for MCP server '#{server}'.

    Valid transports are: "stdio", "http", "websocket"

    This error often occurs with outdated config values (e.g., "streamable_http" from older versions).

    To fix:
    1. Manually edit ~/.fnord/settings.json and change the transport value to a valid one
    2. Or remove the server config and re-add it: fnord config mcp remove #{server} && fnord config mcp add #{server} [options]
    """)

    raise ArgumentError, "Invalid transport '#{transport}' for MCP server '#{server}'"
  end

  def map(server, cfg) do
    UI.error("""
    Missing or invalid transport configuration for MCP server '#{server}'.

    Config received: #{inspect(cfg)}

    To fix:
    1. Manually edit ~/.fnord/settings.json to add a valid "transport" field
    2. Or remove the server config and re-add it: fnord config mcp remove #{server} && fnord config mcp add #{server} [options]
    """)

    raise ArgumentError, "Missing transport configuration for MCP server '#{server}'"
  end

  # Hermes builds the request URL as URI.append_path(base_url, mcp_path),
  # with mcp_path defaulting to "/". A base_url that already carries the
  # endpoint path (e.g. https://mcp.linear.app/mcp) would be mangled to
  # ".../mcp/" - and servers route the trailing-slash form as a distinct,
  # usually nonexistent, path. So: an explicit mcp_path passes through with
  # Hermes's append semantics intact (base_url is the origin, mcp_path the
  # endpoint); without one, the configured base_url is treated as the
  # complete endpoint URL and split into origin + path so the request hits
  # exactly the URL the user configured.
  defp split_endpoint(cfg) do
    base_url = cfg["base_url"]

    case Map.get(cfg, "mcp_path") do
      path when is_binary(path) ->
        {base_url, path}

      _ ->
        uri = URI.parse(base_url)

        case uri.path do
          path when is_binary(path) and path != "" ->
            {URI.to_string(%{uri | path: nil}), path}

          _ ->
            {base_url, "/"}
        end
    end
  end

  # Inject OAuth Authorization header if server has oauth config and valid credentials
  defp merge_oauth_header(server, cfg, base_headers) do
    case Map.get(cfg, "oauth") do
      nil ->
        base_headers

      oauth_cfg when is_map(oauth_cfg) ->
        case MCP.OAuth2.Bridge.authorization_header(server, cfg) do
          {:ok, oauth_headers} ->
            # Convert list of tuples to map and merge with base headers
            oauth_map = Map.new(oauth_headers)
            Map.merge(base_headers, oauth_map)

          {:error, reason} when reason in [:no_credentials, :not_found] ->
            UI.warn(
              "MCP server '#{server}' has OAuth config but no credentials. To fix",
              "fnord config mcp login #{server}"
            )

            base_headers

          {:error, :no_refresh_token} ->
            UI.warn(
              "MCP server '#{server}' has expired credentials with no refresh token. To fix",
              "fnord config mcp login #{server}"
            )

            base_headers

          {:error, reason} ->
            UI.warn("Failed to get OAuth token for MCP server '#{server}'", reason)

            base_headers
        end
    end
  end
end

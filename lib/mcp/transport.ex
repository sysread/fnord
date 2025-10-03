defmodule MCP.Transport do
  @moduledoc false

  require Logger

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
       command: cfg["command"],
       args: cfg["args"] || [],
       env: cfg["env"] || %{}
     ]}
  end

  def map(server, %{"transport" => "streamable_http"} = cfg) do
    headers = merge_oauth_header(server, cfg, cfg["headers"] || %{})

    {:streamable_http,
     [
       base_url: cfg["base_url"],
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
            Logger.warning(
              "MCP server '#{server}' has OAuth config but no credentials. Run: fnord config mcp login #{server}"
            )

            base_headers

          {:error, reason} ->
            Logger.warning(
              "Failed to get OAuth token for MCP server '#{server}': #{inspect(reason)}"
            )

            base_headers
        end
    end
  end
end

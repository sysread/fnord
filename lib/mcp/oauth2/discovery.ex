defmodule MCP.OAuth2.Discovery do
  @moduledoc """
  OAuth2 server discovery and automatic configuration.
  Implements RFC 8414 Authorization Server Metadata discovery.
  """

  require Logger
  alias MCP.OAuth2.Registration

  @doc """
  Discover OAuth2 configuration and set up authentication automatically.

  ## Parameters
    - base_url: The MCP server's base URL
    - opts: Configuration options
      - :client_id - Use existing client_id (skip registration)
      - :client_secret - Client secret (optional)
      - :scope - List of scopes (default: auto-detect)
      - :redirect_port - Port to use for redirect URI (for registration)

  ## Returns
    - {:ok, oauth_config} - Ready-to-use OAuth configuration map
    - {:error, reason} - Discovery or setup failed

  ## OAuth Config Structure
    %{
      "discovery_url" => String.t(),
      "client_id" => String.t(),
      "client_secret" => String.t() | nil,
      "scopes" => [String.t()]
    }
  """
  @spec discover_and_setup(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def discover_and_setup(base_url, opts \\ []) do
    with {:ok, discovery_url} <- build_discovery_url(base_url),
         {:ok, metadata} <- fetch_metadata(discovery_url),
         :ok <- validate_metadata(metadata),
         {:ok, client_id, client_secret} <- ensure_client_credentials(metadata, opts),
         {:ok, scopes} <- determine_scopes(metadata, opts) do
      oauth_config = %{
        "discovery_url" => discovery_url,
        "client_id" => client_id,
        "client_secret" => client_secret,
        "scopes" => scopes
      }

      # Include redirect_port if it was provided (for exact URI matching)
      oauth_with_port =
        case opts[:redirect_port] do
          port when is_integer(port) ->
            Map.put(oauth_config, "redirect_port", port)

          _ ->
            oauth_config
        end

      log_setup_success(client_id, scopes)
      {:ok, oauth_with_port}
    end
  end

  # Build the well-known OAuth discovery URL
  defp build_discovery_url(base_url) do
    url =
      base_url
      |> String.trim_trailing("/")
      |> Kernel.<>("/.well-known/oauth-authorization-server")

    {:ok, url}
  end

  # Fetch OAuth authorization server metadata
  defp fetch_metadata(discovery_url) do
    MCP.Util.debug("MCP OAuth", "Fetching metadata from #{discovery_url}")

    case HTTPoison.get(discovery_url, [], recv_timeout: 10_000, timeout: 10_000) do
      {:ok, %{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, metadata} when is_map(metadata) ->
            {:ok, metadata}

          {:ok, _} ->
            {:error, {:invalid_metadata, "Discovery response is not a JSON object"}}

          {:error, reason} ->
            {:error, {:invalid_json, reason}}
        end

      {:ok, %{status_code: 404}} ->
        {:error, :discovery_not_found}

      {:ok, %{status_code: code}} ->
        {:error, {:http_error, code}}

      {:error, reason} ->
        {:error, {:network_error, reason}}
    end
  end

  # Validate required OAuth metadata fields
  defp validate_metadata(metadata) do
    required = ["issuer", "authorization_endpoint", "token_endpoint"]

    missing =
      Enum.filter(required, fn field ->
        !Map.has_key?(metadata, field) || is_nil(metadata[field])
      end)

    case missing do
      [] ->
        :ok

      fields ->
        {:error, {:incomplete_metadata, "Missing required fields: #{Enum.join(fields, ", ")}"}}
    end
  end

  # Ensure we have client credentials (either provided or via registration)
  defp ensure_client_credentials(metadata, opts) do
    case opts[:client_id] do
      nil ->
        # No client_id provided, attempt dynamic registration
        register_client(metadata, opts)

      client_id ->
        # Use provided client_id
        MCP.Util.debug("MCP OAuth", "Using provided client_id: #{client_id}")
        {:ok, client_id, opts[:client_secret]}
    end
  end

  # Attempt dynamic client registration
  defp register_client(%{"registration_endpoint" => endpoint}, opts) when is_binary(endpoint) do
    MCP.Util.debug("MCP OAuth", "Attempting dynamic registration at #{endpoint}")

    # If a redirect port is provided, use it for registration
    registration_opts =
      case opts[:redirect_port] do
        port when is_integer(port) ->
          [redirect_uris: ["http://localhost:#{port}/callback"]]

        _ ->
          []
      end

    case Registration.register(endpoint, registration_opts) do
      {:ok, %{client_id: client_id, client_secret: client_secret}} ->
        {:ok, client_id, client_secret}

      {:error, reason} ->
        {:error, {:registration_failed, reason}}
    end
  end

  defp register_client(_metadata, _opts) do
    {:error, :no_registration_endpoint}
  end

  # Determine which scopes to use
  defp determine_scopes(metadata, opts) do
    scopes =
      cond do
        # User explicitly provided scopes
        opts[:scope] && length(opts[:scope]) > 0 ->
          MCP.Util.debug("MCP OAuth", "Using user-provided scopes: #{inspect(opts[:scope])}")
          opts[:scope]

        # Server supports mcp:access (recommended minimal scope)
        has_scope?(metadata, "mcp:access") ->
          MCP.Util.debug("MCP OAuth", "Using recommended scope: mcp:access")
          ["mcp:access"]

        # Fall back to all supported scopes
        true ->
          supported = Map.get(metadata, "scopes_supported", [])
          MCP.Util.debug("MCP OAuth", "Using all supported scopes: #{inspect(supported)}")
          supported
      end

    {:ok, scopes}
  end

  defp has_scope?(%{"scopes_supported" => scopes}, scope) when is_list(scopes) do
    scope in scopes
  end

  defp has_scope?(_, _), do: false

  defp log_setup_success(client_id, scopes) do
    # Only log in non-quiet mode (tests typically run with quiet mode)
    unless UI.quiet?() do
      UI.puts("✓ OAuth configured successfully")
      UI.puts("  Client ID: #{client_id}")
      UI.puts("  Scopes: #{Enum.join(scopes, ", ")}")
      UI.puts("")
    end
  end
end

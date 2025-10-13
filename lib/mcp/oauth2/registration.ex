defmodule MCP.OAuth2.Registration do
  @moduledoc """
  RFC 7591 Dynamic Client Registration for OAuth2.
  Allows automatic registration of native clients with OAuth providers.
  """

  @doc """
  Register a new OAuth client with the authorization server.

  Uses RFC 7591 Dynamic Client Registration to automatically obtain a client_id
  without requiring manual pre-registration.

  ## Parameters
    - registration_endpoint: The registration endpoint URL from discovery
    - opts: Optional overrides
      - :client_name - Application name (default: "fnord")
      - :redirect_uris - Callback URIs (default: ["http://127.0.0.1/callback"])

  ## Returns
    - {:ok, %{client_id: String.t(), client_secret: String.t() | nil}}
    - {:error, reason}
  """
  @spec register(String.t(), keyword()) ::
          {:ok, %{client_id: String.t(), client_secret: String.t() | nil}} | {:error, term()}
  def register(registration_endpoint, opts \\ []) do
    # RFC 8252 section 7.3: Native apps should use loopback with ephemeral port
    # Since many servers require exact URI matches, we use a fixed port (8080)
    default_redirects = [
      "http://localhost:8080/callback"
    ]

    request_body = %{
      "client_name" => opts[:client_name] || "fnord",
      "redirect_uris" => opts[:redirect_uris] || default_redirects,
      "grant_types" => ["authorization_code", "refresh_token"],
      "response_types" => ["code"],
      "token_endpoint_auth_method" => "none",
      "application_type" => "native"
    }

    headers = [{"Content-Type", "application/json"}]

    case HTTPoison.post(
           registration_endpoint,
           Jason.encode!(request_body),
           headers,
           recv_timeout: 15_000,
           timeout: 15_000
         ) do
      {:ok, %{status_code: 201, body: body}} ->
        parse_registration_response(body)

      {:ok, %{status_code: 200, body: body}} ->
        # Some servers return 200 instead of 201
        parse_registration_response(body)

      {:ok, %{status_code: code, body: _body}} ->
        {:error, {:registration_failed, code}}
    end
  rescue
    e in HTTPoison.Error ->
      {:error, {:network_error, e.reason}}
  catch
    _kind, reason ->
      {:error, {:network_error, reason}}
  end

  defp parse_registration_response(body) do
    case Jason.decode(body) do
      {:ok, %{"client_id" => client_id} = response} ->
        result = %{
          client_id: client_id,
          client_secret: Map.get(response, "client_secret")
        }

        MCP.Util.debug("MCP OAuth", "Successfully registered client: #{client_id}")
        {:ok, result}

      {:ok, _} ->
        {:error, :missing_client_id}

      {:error, reason} ->
        {:error, {:invalid_json, reason}}
    end
  end
end

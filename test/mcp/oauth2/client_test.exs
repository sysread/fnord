defmodule MCP.OAuth2.ClientTest do
  use Fnord.TestCase, async: false

  setup do
    # Mock HTTPoison for network calls
    :meck.new(HTTPoison, [:passthrough])

    on_exit(fn ->
      try do
        :meck.unload(HTTPoison)
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  describe "start_flow/1" do
    test "fetches metadata and generates authorization URL with PKCE" do
      cfg = %{
        discovery_url: "https://example.com/.well-known/oauth-authorization-server",
        client_id: "test-client",
        scopes: ["openid"],
        redirect_uri: "http://localhost:3000/callback"
      }

      metadata = %{
        "issuer" => "https://example.com",
        "authorization_endpoint" => "https://example.com/authorize",
        "token_endpoint" => "https://example.com/token"
      }

      :meck.expect(HTTPoison, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: SafeJson.encode!(metadata)}}
      end)

      assert {:ok, %{auth_url: auth_url, state: state, code_verifier: verifier}} =
               MCP.OAuth2.Client.start_flow(cfg)

      # Verify auth_url contains required parameters
      assert String.contains?(auth_url, "https://example.com/authorize")
      assert String.contains?(auth_url, "client_id=test-client")
      assert String.contains?(auth_url, "response_type=code")
      assert String.contains?(auth_url, "redirect_uri=http")
      assert String.contains?(auth_url, "code_challenge=")
      assert String.contains?(auth_url, "code_challenge_method=S256")

      # Verify state and verifier are generated
      assert is_binary(state)
      assert byte_size(state) > 0
      assert is_binary(verifier)
      assert byte_size(verifier) > 0
    end

    test "includes the RFC 8707 resource parameter when configured" do
      cfg = %{
        discovery_url: "https://example.com/.well-known/oauth-authorization-server",
        client_id: "test-client",
        scopes: ["read"],
        redirect_uri: "http://localhost:3000/callback",
        resource: "https://example.com/mcp"
      }

      metadata = %{
        "issuer" => "https://example.com",
        "authorization_endpoint" => "https://example.com/authorize",
        "token_endpoint" => "https://example.com/token"
      }

      :meck.expect(HTTPoison, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: SafeJson.encode!(metadata)}}
      end)

      assert {:ok, %{auth_url: auth_url}} = MCP.OAuth2.Client.start_flow(cfg)

      %{query: query} = URI.parse(auth_url)
      assert URI.decode_query(query)["resource"] == "https://example.com/mcp"
    end

    test "omits the resource parameter when not configured" do
      cfg = %{
        discovery_url: "https://example.com/.well-known/oauth-authorization-server",
        client_id: "test-client",
        scopes: ["read"],
        redirect_uri: "http://localhost:3000/callback"
      }

      metadata = %{
        "issuer" => "https://example.com",
        "authorization_endpoint" => "https://example.com/authorize",
        "token_endpoint" => "https://example.com/token"
      }

      :meck.expect(HTTPoison, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: SafeJson.encode!(metadata)}}
      end)

      assert {:ok, %{auth_url: auth_url}} = MCP.OAuth2.Client.start_flow(cfg)

      %{query: query} = URI.parse(auth_url)
      refute Map.has_key?(URI.decode_query(query), "resource")
    end

    test "returns error when discovery fails" do
      cfg = %{
        discovery_url: "https://example.com/.well-known/oauth-authorization-server",
        client_id: "test-client",
        scopes: ["openid"],
        redirect_uri: "http://localhost:3000/callback"
      }

      :meck.expect(HTTPoison, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 404, body: "Not found"}}
      end)

      assert {:error, {:http_error, 404}} = MCP.OAuth2.Client.start_flow(cfg)
    end
  end

  describe "handle_callback/4" do
    test "exchanges code for tokens" do
      cfg = %{
        discovery_url: "https://example.com/.well-known/oauth-authorization-server",
        client_id: "test-client",
        client_secret: "test-secret",
        scopes: ["openid"],
        redirect_uri: "http://localhost:3000/callback"
      }

      metadata = %{
        "issuer" => "https://example.com",
        "authorization_endpoint" => "https://example.com/authorize",
        "token_endpoint" => "https://example.com/token"
      }

      token_response = %{
        "access_token" => "access-123",
        "token_type" => "Bearer",
        "expires_in" => 3600
      }

      :meck.expect(HTTPoison, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: SafeJson.encode!(metadata)}}
      end)

      :meck.expect(HTTPoison, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status_code: 200, body: SafeJson.encode!(token_response)}}
      end)

      params = %{"code" => "auth-code", "state" => "test-state"}

      assert {:ok, tokens} =
               MCP.OAuth2.Client.handle_callback(cfg, params, "test-state", "verifier")

      assert tokens.access_token == "access-123"
      assert tokens.token_type == "Bearer"
      assert is_integer(tokens.expires_at)
    end

    test "token exchange carries the resource parameter when configured" do
      cfg = %{
        discovery_url: "https://example.com/.well-known/oauth-authorization-server",
        client_id: "test-client",
        scopes: ["read"],
        redirect_uri: "http://localhost:3000/callback",
        resource: "https://example.com/mcp"
      }

      metadata = %{
        "issuer" => "https://example.com",
        "authorization_endpoint" => "https://example.com/authorize",
        "token_endpoint" => "https://example.com/token"
      }

      token_response = %{
        "access_token" => "access-123",
        "token_type" => "Bearer",
        "expires_in" => 3600
      }

      :meck.expect(HTTPoison, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: SafeJson.encode!(metadata)}}
      end)

      # Surface the form-encoded POST body to the test pid; asserting inside
      # the meck callback would be swallowed by the call site.
      test_pid = self()

      :meck.expect(HTTPoison, :post, fn _url, body, _headers, _opts ->
        send(test_pid, {:token_request_body, body})
        {:ok, %{status_code: 200, body: SafeJson.encode!(token_response)}}
      end)

      params = %{"code" => "auth-code", "state" => "test-state"}

      assert {:ok, _tokens} =
               MCP.OAuth2.Client.handle_callback(cfg, params, "test-state", "verifier")

      assert_receive {:token_request_body, body}
      assert URI.decode_query(body)["resource"] == "https://example.com/mcp"
    end

    test "returns error when state mismatch" do
      cfg = %{
        discovery_url: "https://example.com/.well-known/oauth-authorization-server",
        client_id: "test-client",
        scopes: ["openid"],
        redirect_uri: "http://localhost:3000/callback"
      }

      metadata = %{
        "issuer" => "https://example.com",
        "authorization_endpoint" => "https://example.com/authorize",
        "token_endpoint" => "https://example.com/token"
      }

      :meck.expect(HTTPoison, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: SafeJson.encode!(metadata)}}
      end)

      params = %{"code" => "auth-code", "state" => "wrong-state"}

      assert {:error, :state_mismatch} =
               MCP.OAuth2.Client.handle_callback(cfg, params, "expected-state", "verifier")
    end
  end

  describe "refresh_token/2" do
    test "refreshes access token using refresh token" do
      cfg = %{
        discovery_url: "https://example.com/.well-known/oauth-authorization-server",
        client_id: "test-client",
        client_secret: "test-secret"
      }

      metadata = %{
        "issuer" => "https://example.com",
        "authorization_endpoint" => "https://example.com/authorize",
        "token_endpoint" => "https://example.com/token"
      }

      token_response = %{
        "access_token" => "new-access-123",
        "token_type" => "Bearer",
        "expires_in" => 3600,
        "refresh_token" => "new-refresh-123"
      }

      :meck.expect(HTTPoison, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: SafeJson.encode!(metadata)}}
      end)

      :meck.expect(HTTPoison, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status_code: 200, body: SafeJson.encode!(token_response)}}
      end)

      assert {:ok, tokens} = MCP.OAuth2.Client.refresh_token(cfg, "old-refresh-token")

      assert tokens.access_token == "new-access-123"
      assert tokens.refresh_token == "new-refresh-123"
    end

    test "refresh carries the resource parameter when configured" do
      cfg = %{
        discovery_url: "https://example.com/.well-known/oauth-authorization-server",
        client_id: "test-client",
        resource: "https://example.com/mcp"
      }

      metadata = %{
        "issuer" => "https://example.com",
        "authorization_endpoint" => "https://example.com/authorize",
        "token_endpoint" => "https://example.com/token"
      }

      token_response = %{
        "access_token" => "new-access-123",
        "token_type" => "Bearer",
        "expires_in" => 3600
      }

      :meck.expect(HTTPoison, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: SafeJson.encode!(metadata)}}
      end)

      test_pid = self()

      :meck.expect(HTTPoison, :post, fn _url, body, _headers, _opts ->
        send(test_pid, {:token_request_body, body})
        {:ok, %{status_code: 200, body: SafeJson.encode!(token_response)}}
      end)

      assert {:ok, _tokens} = MCP.OAuth2.Client.refresh_token(cfg, "old-refresh-token")

      assert_receive {:token_request_body, body}
      assert URI.decode_query(body)["resource"] == "https://example.com/mcp"
    end
  end
end

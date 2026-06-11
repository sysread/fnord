defmodule MCP.OAuth2.DiscoveryTest do
  use Fnord.TestCase, async: true

  describe "discover_and_setup/2" do
    test "discovers OAuth metadata from authorization server endpoint" do
      metadata = %{
        "issuer" => "https://example.com",
        "authorization_endpoint" => "https://example.com/authorize",
        "token_endpoint" => "https://example.com/token"
      }

      stub(Http.Client.Mock, :get, fn url, _headers, _opts ->
        assert String.ends_with?(url, ".well-known/oauth-authorization-server")
        {:ok, %{status_code: 200, body: SafeJson.encode!(metadata)}}
      end)

      assert {:ok, config} =
               MCP.OAuth2.Discovery.discover_and_setup("https://example.com",
                 client_id: "test-client",
                 scope: ["mcp:access"]
               )

      assert config["discovery_url"] ==
               "https://example.com/.well-known/oauth-authorization-server"

      assert config["client_id"] == "test-client"
      assert config["scopes"] == ["mcp:access"]
    end

    test "returns error when discovery fails" do
      stub(Http.Client.Mock, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 404, body: "Not found"}}
      end)

      assert {:error, :discovery_not_found} =
               MCP.OAuth2.Discovery.discover_and_setup("https://example.com",
                 client_id: "test-client"
               )
    end

    test "performs dynamic registration when no client_id provided" do
      metadata = %{
        "issuer" => "https://example.com",
        "authorization_endpoint" => "https://example.com/authorize",
        "token_endpoint" => "https://example.com/token",
        "registration_endpoint" => "https://example.com/register"
      }

      stub(Http.Client.Mock, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: SafeJson.encode!(metadata)}}
      end)

      # Dynamic registration goes over the wire as an RFC 7591 POST; stub it
      # at the transport and assert the redirect_port flowed through to the
      # registered callback URI.
      stub(Http.Client.Mock, :post, fn url, body, _headers, _opts ->
        assert url == "https://example.com/register"
        assert SafeJson.decode!(body)["redirect_uris"] == ["http://localhost:8080/callback"]

        {:ok, %{status_code: 201, body: SafeJson.encode!(%{"client_id" => "dynamic-client-123"})}}
      end)

      assert {:ok, config} =
               MCP.OAuth2.Discovery.discover_and_setup("https://example.com",
                 scope: ["openid"],
                 redirect_port: 8080
               )

      assert config["client_id"] == "dynamic-client-123"
      assert config["scopes"] == ["openid"]
    end

    test "preserves redirect_port when provided" do
      metadata = %{
        "issuer" => "https://example.com",
        "authorization_endpoint" => "https://example.com/authorize",
        "token_endpoint" => "https://example.com/token"
      }

      stub(Http.Client.Mock, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: SafeJson.encode!(metadata)}}
      end)

      assert {:ok, config} =
               MCP.OAuth2.Discovery.discover_and_setup("https://example.com",
                 client_id: "test-client",
                 redirect_port: 8080
               )

      assert config["redirect_port"] == 8080
    end

    test "determines scopes from scope list option" do
      metadata = %{
        "issuer" => "https://example.com",
        "authorization_endpoint" => "https://example.com/authorize",
        "token_endpoint" => "https://example.com/token"
      }

      stub(Http.Client.Mock, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: SafeJson.encode!(metadata)}}
      end)

      assert {:ok, config} =
               MCP.OAuth2.Discovery.discover_and_setup("https://example.com",
                 client_id: "test-client",
                 scope: ["openid", "profile", "email"]
               )

      assert config["scopes"] == ["openid", "profile", "email"]
    end

    test "returns error when registration required but not available" do
      metadata = %{
        "issuer" => "https://example.com",
        "authorization_endpoint" => "https://example.com/authorize",
        "token_endpoint" => "https://example.com/token"
      }

      stub(Http.Client.Mock, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: SafeJson.encode!(metadata)}}
      end)

      assert {:error, :no_registration_endpoint} =
               MCP.OAuth2.Discovery.discover_and_setup("https://example.com")
    end
  end
end

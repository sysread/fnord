defmodule MCP.OAuth2.DiscoveryTest do
  use Fnord.TestCase, async: false

  setup do
    :meck.new(HTTPoison, [:passthrough])
    :meck.new(MCP.OAuth2.Registration, [:passthrough])

    on_exit(fn ->
      for m <- [HTTPoison, MCP.OAuth2.Registration] do
        try do
          :meck.unload(m)
        catch
          _, _ -> :ok
        end
      end
    end)

    :ok
  end

  describe "discover_and_setup/2" do
    test "discovers OAuth metadata from authorization server endpoint" do
      metadata = %{
        "issuer" => "https://example.com",
        "authorization_endpoint" => "https://example.com/authorize",
        "token_endpoint" => "https://example.com/token"
      }

      :meck.expect(HTTPoison, :get, fn url, _headers, _opts ->
        assert String.ends_with?(url, ".well-known/oauth-authorization-server")
        {:ok, %{status_code: 200, body: Jason.encode!(metadata)}}
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
      :meck.expect(HTTPoison, :get, fn _url, _headers, _opts ->
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

      :meck.expect(HTTPoison, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: Jason.encode!(metadata)}}
      end)

      :meck.expect(MCP.OAuth2.Registration, :register, fn endpoint, opts ->
        assert endpoint == "https://example.com/register"
        assert opts[:redirect_uris] == ["http://localhost:8080/callback"]
        {:ok, %{client_id: "dynamic-client-123", client_secret: nil}}
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

      :meck.expect(HTTPoison, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: Jason.encode!(metadata)}}
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

      :meck.expect(HTTPoison, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: Jason.encode!(metadata)}}
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

      :meck.expect(HTTPoison, :get, fn _url, _headers, _opts ->
        {:ok, %{status_code: 200, body: Jason.encode!(metadata)}}
      end)

      assert {:error, :no_registration_endpoint} =
               MCP.OAuth2.Discovery.discover_and_setup("https://example.com")
    end
  end
end

defmodule MCP.OAuth2.BridgeTest do
  use Fnord.TestCase, async: true

  # ---------------------------------------------------------------------------
  # Credentials are real files under the per-test HOME and the real
  # MCP.OAuth2.Client performs the refresh; only the authorization server's
  # endpoints (discovery + token) are canned at the HTTP transport seam, so
  # assertions observe the actual wire protocol of the refresh request.
  # ---------------------------------------------------------------------------

  @discovery_url "https://example.com/.well-known/openid-configuration"
  @token_endpoint "https://example.com/token"

  defp cfg() do
    %{
      "oauth" => %{
        "discovery_url" => @discovery_url,
        "client_id" => "c",
        "scopes" => ["openid"]
      }
    }
  end

  # Cans the AS: discovery serves the token endpoint; the token endpoint
  # forwards each request body to the test and issues a fresh token.
  defp script_token_refresh() do
    test_pid = self()

    Mox.stub(Http.Client.Mock, :get, fn @discovery_url, _headers, _opts ->
      metadata = %{
        "authorization_endpoint" => "https://example.com/authorize",
        "token_endpoint" => @token_endpoint
      }

      {:ok, %{status_code: 200, body: SafeJson.encode!(metadata)}}
    end)

    Mox.stub(Http.Client.Mock, :post, fn @token_endpoint, body, _headers, _opts ->
      send(test_pid, {:token_request, URI.decode_query(body)})

      tokens = %{
        "access_token" => "new",
        "refresh_token" => "rt2",
        "token_type" => "Bearer",
        "expires_in" => 3600,
        "scope" => "openid"
      }

      {:ok, %{status_code: 200, body: SafeJson.encode!(tokens)}}
    end)
  end

  test "returns header when access token is present and not near expiry" do
    now = System.os_time(:second)

    :ok =
      MCP.OAuth2.CredentialsStore.write("srv1", %{
        "access_token" => "at",
        "expires_at" => now + 10_000
      })

    assert {:ok, [{"authorization", "Bearer at"}]} =
             MCP.OAuth2.Bridge.authorization_header("srv1", cfg())
  end

  test "refreshes near expiry and persists the new token" do
    now = System.os_time(:second)

    :ok =
      MCP.OAuth2.CredentialsStore.write("srv1", %{
        "access_token" => "old",
        "refresh_token" => "rt",
        "expires_at" => now + 10
      })

    script_token_refresh()

    assert {:ok, [{"authorization", "Bearer new"}]} =
             MCP.OAuth2.Bridge.authorization_header("srv1", cfg(), refresh_margin: 120)

    # The refresh request is a standard RFC 6749 section 6 token request.
    assert_received {:token_request, params}
    assert params["grant_type"] == "refresh_token"
    assert params["refresh_token"] == "rt"
    assert params["client_id"] == "c"

    # The rotated token was persisted to the real credentials store.
    assert {:ok, stored} = MCP.OAuth2.CredentialsStore.read("srv1")
    assert stored["access_token"] == "new"
    assert stored["refresh_token"] == "rt2"
  end

  test "errors when no credentials" do
    assert {:error, :not_found} = MCP.OAuth2.Bridge.authorization_header("srv1", cfg())
  end

  test "errors when no refresh token and near expiry" do
    now = System.os_time(:second)

    :ok =
      MCP.OAuth2.CredentialsStore.write("srv1", %{
        "access_token" => "at",
        "expires_at" => now + 10
      })

    assert {:error, :no_refresh_token} =
             MCP.OAuth2.Bridge.authorization_header("srv1", cfg(), refresh_margin: 120)
  end

  test "refresh omits the RFC 8707 resource when no base_url is configured" do
    now = System.os_time(:second)

    :ok =
      MCP.OAuth2.CredentialsStore.write("srv1", %{
        "access_token" => "old",
        "refresh_token" => "rt",
        "expires_at" => now + 10
      })

    script_token_refresh()

    assert {:ok, _} = MCP.OAuth2.Bridge.authorization_header("srv1", cfg(), refresh_margin: 120)

    assert_received {:token_request, params}
    refute Map.has_key?(params, "resource")
  end

  test "refresh threads the server base_url through as the RFC 8707 resource" do
    now = System.os_time(:second)

    cfg_with_base = Map.put(cfg(), "base_url", "https://mcp.example.com/mcp")

    :ok =
      MCP.OAuth2.CredentialsStore.write("srv1", %{
        "access_token" => "old",
        "refresh_token" => "rt",
        "expires_at" => now + 10
      })

    script_token_refresh()

    assert {:ok, [{"authorization", "Bearer new"}]} =
             MCP.OAuth2.Bridge.authorization_header("srv1", cfg_with_base, refresh_margin: 120)

    assert_received {:token_request, params}
    assert params["resource"] == "https://mcp.example.com/mcp"
  end
end

defmodule MCP.OAuth2.BridgeTest do
  use Fnord.TestCase, async: false

  setup do
    # meck CredentialsStore and Client interactions
    :meck.new(MCP.OAuth2.CredentialsStore, [:non_strict])
    :meck.new(MCP.OAuth2.Client, [:non_strict])

    on_exit(fn ->
      for m <- [MCP.OAuth2.CredentialsStore, MCP.OAuth2.Client] do
        try do
          :meck.unload(m)
        catch
          _, _ -> :ok
        end
      end
    end)

    :ok
  end

  defp cfg(),
    do: %{
      "oauth" => %{
        "discovery_url" => "https://example.com/.well-known/openid-configuration",
        "client_id" => "c",
        "scopes" => ["openid"]
      }
    }

  test "returns header when access token is present and not near expiry" do
    now = System.os_time(:second)

    :meck.expect(MCP.OAuth2.CredentialsStore, :read, fn "srv1" ->
      {:ok, %{"access_token" => "at", "expires_at" => now + 10_000}}
    end)

    assert {:ok, [{"authorization", "Bearer at"}]} =
             MCP.OAuth2.Bridge.authorization_header("srv1", cfg())
  end

  test "refreshes near expiry and persists" do
    now = System.os_time(:second)

    :meck.expect(MCP.OAuth2.CredentialsStore, :read, fn "srv1" ->
      {:ok, %{"access_token" => "old", "refresh_token" => "rt", "expires_at" => now + 10}}
    end)

    :meck.expect(MCP.OAuth2.Client, :refresh_token, fn _cfg, "rt" ->
      {:ok,
       %{
         access_token: "new",
         refresh_token: "rt",
         token_type: "Bearer",
         expires_at: now + 3600,
         scope: "openid"
       }}
    end)

    :meck.expect(MCP.OAuth2.CredentialsStore, :write, fn "srv1", m ->
      assert m["access_token"] == "new"
      :ok
    end)

    assert {:ok, [{"authorization", "Bearer new"}]} =
             MCP.OAuth2.Bridge.authorization_header("srv1", cfg(), refresh_margin: 120)
  end

  test "errors when no credentials" do
    :meck.expect(MCP.OAuth2.CredentialsStore, :read, fn _ -> {:error, :not_found} end)
    assert {:error, :not_found} = MCP.OAuth2.Bridge.authorization_header("srv1", cfg())
  end

  test "errors when no refresh token and near expiry" do
    now = System.os_time(:second)

    :meck.expect(MCP.OAuth2.CredentialsStore, :read, fn _ ->
      {:ok, %{"access_token" => "at", "expires_at" => now + 10}}
    end)

    assert {:error, :no_refresh_token} =
             MCP.OAuth2.Bridge.authorization_header("srv1", cfg(), refresh_margin: 120)
  end

  test "refresh uses redirect_port when configured" do
    now = System.os_time(:second)

    cfg_with_port = %{
      "oauth" => %{
        "discovery_url" => "https://example.com/.well-known/openid-configuration",
        "client_id" => "c",
        "scopes" => ["openid"],
        "redirect_port" => 5555
      }
    }

    :meck.expect(MCP.OAuth2.CredentialsStore, :read, fn "srv1" ->
      {:ok, %{"access_token" => "old", "refresh_token" => "rt", "expires_at" => now + 10}}
    end)

    :meck.expect(MCP.OAuth2.Client, :refresh_token, fn oauth_cfg, "rt" ->
      # Verify redirect_uri was built from redirect_port
      assert oauth_cfg[:redirect_uri] == "http://localhost:5555/callback"

      {:ok,
       %{
         access_token: "new",
         refresh_token: "rt",
         token_type: "Bearer",
         expires_at: now + 3600,
         scope: "openid"
       }}
    end)

    :meck.expect(MCP.OAuth2.CredentialsStore, :write, fn "srv1", _ -> :ok end)

    assert {:ok, [{"authorization", "Bearer new"}]} =
             MCP.OAuth2.Bridge.authorization_header("srv1", cfg_with_port, refresh_margin: 120)
  end

  test "refresh uses explicit redirect_uri when configured" do
    now = System.os_time(:second)

    cfg_with_uri = %{
      "oauth" => %{
        "discovery_url" => "https://example.com/.well-known/openid-configuration",
        "client_id" => "c",
        "scopes" => ["openid"],
        "redirect_uri" => "https://custom.example.com/auth/callback"
      }
    }

    :meck.expect(MCP.OAuth2.CredentialsStore, :read, fn "srv1" ->
      {:ok, %{"access_token" => "old", "refresh_token" => "rt", "expires_at" => now + 10}}
    end)

    :meck.expect(MCP.OAuth2.Client, :refresh_token, fn oauth_cfg, "rt" ->
      # Verify explicit redirect_uri was used
      assert oauth_cfg[:redirect_uri] == "https://custom.example.com/auth/callback"

      {:ok,
       %{
         access_token: "new",
         refresh_token: "rt",
         token_type: "Bearer",
         expires_at: now + 3600,
         scope: "openid"
       }}
    end)

    :meck.expect(MCP.OAuth2.CredentialsStore, :write, fn "srv1", _ -> :ok end)

    assert {:ok, [{"authorization", "Bearer new"}]} =
             MCP.OAuth2.Bridge.authorization_header("srv1", cfg_with_uri, refresh_margin: 120)
  end

  test "refresh omits redirect_uri when neither configured" do
    now = System.os_time(:second)

    :meck.expect(MCP.OAuth2.CredentialsStore, :read, fn "srv1" ->
      {:ok, %{"access_token" => "old", "refresh_token" => "rt", "expires_at" => now + 10}}
    end)

    :meck.expect(MCP.OAuth2.Client, :refresh_token, fn oauth_cfg, "rt" ->
      # Verify redirect_uri was not included
      refute Map.has_key?(oauth_cfg, :redirect_uri)

      {:ok,
       %{
         access_token: "new",
         refresh_token: "rt",
         token_type: "Bearer",
         expires_at: now + 3600,
         scope: "openid"
       }}
    end)

    :meck.expect(MCP.OAuth2.CredentialsStore, :write, fn "srv1", _ -> :ok end)

    assert {:ok, [{"authorization", "Bearer new"}]} =
             MCP.OAuth2.Bridge.authorization_header("srv1", cfg(), refresh_margin: 120)
  end

  test "refresh prefers explicit redirect_uri over redirect_port" do
    now = System.os_time(:second)

    cfg_with_both = %{
      "oauth" => %{
        "discovery_url" => "https://example.com/.well-known/openid-configuration",
        "client_id" => "c",
        "scopes" => ["openid"],
        "redirect_uri" => "https://custom.example.com/auth/callback",
        "redirect_port" => 5555
      }
    }

    :meck.expect(MCP.OAuth2.CredentialsStore, :read, fn "srv1" ->
      {:ok, %{"access_token" => "old", "refresh_token" => "rt", "expires_at" => now + 10}}
    end)

    :meck.expect(MCP.OAuth2.Client, :refresh_token, fn oauth_cfg, "rt" ->
      # Verify explicit redirect_uri takes precedence over redirect_port
      assert oauth_cfg[:redirect_uri] == "https://custom.example.com/auth/callback"

      {:ok,
       %{
         access_token: "new",
         refresh_token: "rt",
         token_type: "Bearer",
         expires_at: now + 3600,
         scope: "openid"
       }}
    end)

    :meck.expect(MCP.OAuth2.CredentialsStore, :write, fn "srv1", _ -> :ok end)

    assert {:ok, [{"authorization", "Bearer new"}]} =
             MCP.OAuth2.Bridge.authorization_header("srv1", cfg_with_both, refresh_margin: 120)
  end
end

defmodule MCP.OAuth2.BridgeTest do
  use ExUnit.Case, async: false

  setup do
    # meck CredentialsStore and OidccAdapter interactions
    :meck.new(MCP.OAuth2.CredentialsStore, [:non_strict])
    :meck.new(MCP.OAuth2.OidccAdapter, [:non_strict])

    on_exit(fn ->
      for m <- [MCP.OAuth2.CredentialsStore, MCP.OAuth2.OidccAdapter] do
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
      discovery_url: "https://example.com/.well-known/openid-configuration",
      client_id: "c",
      redirect_uri: "http://127.0.0.1:7/callback",
      scopes: ["openid"]
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

    :meck.expect(MCP.OAuth2.OidccAdapter, :refresh_token, fn _cfg, %{refresh_token: "rt"} ->
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
end

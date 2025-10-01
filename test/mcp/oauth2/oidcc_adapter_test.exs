defmodule MCP.OAuth2.OidccAdapterTest do
  use ExUnit.Case, async: false

  require Record

  # Import Oidcc Token records for constructing test records
  Record.defrecord(
    :oidcc_token,
    Record.extract(:oidcc_token, from_lib: "oidcc/include/oidcc_token.hrl")
  )

  Record.defrecord(
    :oidcc_token_access,
    Record.extract(:oidcc_token_access, from_lib: "oidcc/include/oidcc_token.hrl")
  )

  Record.defrecord(
    :oidcc_token_refresh,
    Record.extract(:oidcc_token_refresh, from_lib: "oidcc/include/oidcc_token.hrl")
  )

  setup do
    # Quiet logger noise if any
    old = Logger.level()
    Logger.configure(level: :error)
    on_exit(fn -> Logger.configure(level: old) end)
    :ok
  end

  setup do
    # meck external dependencies used by the adapter
    :meck.new(HTTPoison, [:non_strict])
    :meck.new(:oidcc_provider_configuration_worker, [:non_strict])
    :meck.new(:oidcc, [:non_strict])

    on_exit(fn ->
      for m <- [HTTPoison, :oidcc_provider_configuration_worker, :oidcc] do
        try do
          :meck.unload(m)
        catch
          _, _ -> :ok
        end
      end
    end)

    :ok
  end

  defp cfg_base() do
    %{
      discovery_url: "https://example.com/.well-known/openid-configuration",
      client_id: "client-123",
      redirect_uri: "http://127.0.0.1:7777/callback",
      scopes: ["openid", "offline_access"]
    }
    |> Map.put(:client_secret, nil)
  end

  test "start_flow returns url, state, and verifier" do
    :meck.expect(HTTPoison, :get, fn url, _hdrs, _opts ->
      assert String.contains?(url, "/.well-known/openid-configuration")
      {:ok, %{status_code: 200, body: ~s({"issuer":"https://issuer"})}}
    end)

    :meck.expect(:oidcc_provider_configuration_worker, :start_link, fn %{
                                                                         issuer:
                                                                           ~c"https://issuer"
                                                                       } ->
      {:ok, self()}
    end)

    :meck.expect(:oidcc, :create_redirect_url, fn _provider, _client_id, _client_secret, _opts ->
      {:ok, ~c"https://issuer/authorize?abc"}
    end)

    {:ok, %{auth_url: url, state: state, code_verifier: verifier}} =
      MCP.OAuth2.OidccAdapter.start_flow(cfg_base())

    assert is_binary(url) and String.starts_with?(url, "https://issuer/")
    assert is_binary(state) and byte_size(state) > 8
    assert is_binary(verifier) and byte_size(verifier) > 8
  end

  test "handle_callback returns error for state mismatch and missing code" do
    # state mismatch
    assert {:error, :state_mismatch} =
             MCP.OAuth2.OidccAdapter.handle_callback(
               cfg_base(),
               %{"code" => "abc", "state" => "bad"},
               "good",
               "v"
             )

    # missing code
    assert {:error, :no_code} =
             MCP.OAuth2.OidccAdapter.handle_callback(cfg_base(), %{"state" => "s"}, "s", "v")
  end

  test "handle_callback success normalizes token" do
    :meck.expect(HTTPoison, :get, fn _url, _hdrs, _opts ->
      {:ok, %{status_code: 200, body: ~s({"issuer":"https://issuer"})}}
    end)

    :meck.expect(:oidcc_provider_configuration_worker, :start_link, fn %{
                                                                         issuer:
                                                                           ~c"https://issuer"
                                                                       } ->
      {:ok, self()}
    end)

    # build a token record similar to what oidcc would return
    access = oidcc_token_access(token: ~c"at", type: ~c"Bearer", expires: 3600)
    refresh = oidcc_token_refresh(token: ~c"rt")
    token_rec = oidcc_token(access: access, refresh: refresh, scope: [~c"openid"])

    :meck.expect(:oidcc, :retrieve_token, fn _code,
                                             _provider,
                                             _client_id,
                                             _client_secret,
                                             _opts ->
      {:ok, token_rec}
    end)

    {:ok, tok} =
      MCP.OAuth2.OidccAdapter.handle_callback(
        cfg_base(),
        %{"code" => "abc", "state" => "x"},
        "x",
        "ver"
      )

    assert tok.access_token == "at"
    assert tok.refresh_token == "rt"
    assert tok.token_type == "Bearer"
    assert is_integer(tok.expires_at) and tok.expires_at > System.os_time(:second)
    assert tok.scope in ["openid", "openid "]
  end

  test "refresh_token normalizes token" do
    :meck.expect(HTTPoison, :get, fn _url, _hdrs, _opts ->
      {:ok, %{status_code: 200, body: ~s({"issuer":"https://issuer"})}}
    end)

    :meck.expect(:oidcc_provider_configuration_worker, :start_link, fn %{
                                                                         issuer:
                                                                           ~c"https://issuer"
                                                                       } ->
      {:ok, self()}
    end)

    access = oidcc_token_access(token: ~c"at2", type: ~c"Bearer", expires: 1800)
    refresh = oidcc_token_refresh(token: ~c"rt2")
    token_rec = oidcc_token(access: access, refresh: refresh, scope: [~c"offline_access"])

    :meck.expect(:oidcc, :refresh_token, fn _rt, _provider, _client_id, _client_secret, _opts ->
      {:ok, token_rec}
    end)

    {:ok, tok} = MCP.OAuth2.OidccAdapter.refresh_token(cfg_base(), %{refresh_token: "rt2"})

    assert tok.access_token == "at2"
    assert tok.refresh_token == "rt2"
    assert tok.token_type == "Bearer"
    assert is_integer(tok.expires_at)
  end
end

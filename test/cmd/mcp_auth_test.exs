defmodule Cmd.McpAuthTest do
  use Fnord.TestCase, async: false
  Code.require_file("test/support/browser_mock.exs")
  import ExUnit.CaptureLog

  setup do
    # Clean settings file
    File.rm_rf!(Settings.settings_file())
    :ok
  end

  setup do
    # Quiet logger to capture only what we need
    old_level = Logger.level()
    Logger.configure(level: :error)
    on_exit(fn -> Logger.configure(level: old_level) end)
    :ok
  end

  setup do
    prev = Application.get_env(:fnord, :browser)
    Application.put_env(:fnord, :browser, Fnord.BrowserMock)
    on_exit(fn -> Application.put_env(:fnord, :browser, prev) end)
    :ok
  end

  defp mock_oauth_server(name) do
    settings = Settings.new()
    # Add minimal valid server with oauth block
    {:ok, settings} =
      Settings.MCP.add_server(settings, :global, name, %{
        "transport" => "stdio",
        "command" => "echo",
        "oauth" => %{
          "discovery_url" => "https://example.com/.well-known/openid-configuration",
          "client_id" => "client-123",
          "scopes" => ["openid", "offline_access"]
        }
      })

    settings
  end

  describe "mcp login happy path" do
    setup do
      mock_oauth_server("authsrv")
      # Mock OidccAdapter.start_flow
      :meck.new(MCP.OAuth2.OidccAdapter, [:non_strict])

      :meck.expect(MCP.OAuth2.OidccAdapter, :start_flow, fn cfg ->
        # ensure redirect_uri present
        assert is_binary(cfg.redirect_uri)
        {:ok, %{auth_url: "https://idp/authorize?abc", state: "xyz", code_verifier: "ver"}}
      end)

      # Mock Loopback.run to return a token
      :meck.new(MCP.OAuth2.Loopback, [:non_strict])

      :meck.expect(MCP.OAuth2.Loopback, :run, fn _cfg, server, state, verifier, _timeout, _port ->
        assert server == "authsrv"
        assert state == "xyz"
        assert verifier == "ver"

        {:ok,
         %{
           "access_token" => "at",
           "token_type" => "Bearer",
           "expires_at" => System.os_time(:second) + 3600,
           "scope" => "openid"
         }}
      end)

      on_exit(fn ->
        for m <- [MCP.OAuth2.OidccAdapter, MCP.OAuth2.Loopback] do
          try do
            :meck.unload(m)
          catch
            _, _ -> :ok
          end
        end
      end)

      :ok
    end

    test "auth succeeds and prints summary" do
      {stdout, stderr} =
        capture_all(fn -> Cmd.Mcp.run(%{timeout: 5000}, [:mcp, :login], ["authsrv"]) end)

      # Presence of redacted summary
      assert stdout <> stderr =~ "token_type"
    end
  end

  describe "mcp login missing server" do
    test "prints not found error" do
      log = capture_log(fn -> Cmd.Mcp.run(%{}, [:mcp, :login], ["nope"]) end)
      assert log =~ "not found"
    end
  end

  describe "provider rejects dynamic redirect" do
    setup do
      mock_oauth_server("rejectsrv")
      :meck.new(MCP.OAuth2.OidccAdapter, [:non_strict])

      :meck.expect(MCP.OAuth2.OidccAdapter, :start_flow, fn _cfg ->
        {:error, {:http_error, 400}}
      end)

      on_exit(fn ->
        try do
          :meck.unload(MCP.OAuth2.OidccAdapter)
        catch
          _, _ -> :ok
        end
      end)

      :ok
    end

    test "shows exact redirect_uri to register" do
      log = capture_log(fn -> Cmd.Mcp.run(%{}, [:mcp, :login], ["rejectsrv"]) end)
      assert log =~ "redirect_uri"
      assert log =~ "http://127.0.0.1:"
    end
  end

  describe "timeout path" do
    setup do
      mock_oauth_server("timeoutsrv")
      :meck.new(MCP.OAuth2.OidccAdapter, [:non_strict])

      :meck.expect(MCP.OAuth2.OidccAdapter, :start_flow, fn _cfg ->
        {:ok, %{auth_url: "https://idp", state: "s", code_verifier: "v"}}
      end)

      :meck.new(MCP.OAuth2.Loopback, [:non_strict])

      :meck.expect(MCP.OAuth2.Loopback, :run, fn _cfg, _s, _st, _v, _to, _p ->
        {:error, :timeout}
      end)

      on_exit(fn ->
        for m <- [MCP.OAuth2.OidccAdapter, MCP.OAuth2.Loopback] do
          try do
            :meck.unload(m)
          catch
            _, _ -> :ok
          end
        end
      end)

      :ok
    end

    test "prints timeout error" do
      log = capture_log(fn -> Cmd.Mcp.run(%{timeout: 1}, [:mcp, :login], ["timeoutsrv"]) end)
      assert log =~ "Timed out"
    end
  end
end

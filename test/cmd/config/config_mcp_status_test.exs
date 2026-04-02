defmodule Cmd.Config.MCP.StatusTest do
  use Fnord.TestCase, async: false
  import ExUnit.CaptureLog

  alias Cmd.Config.MCP.Status

  setup do
    old_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: old_level) end)

    :meck.new(Settings.MCP, [:passthrough])
    :meck.new(MCP.OAuth2.CredentialsStore, [:passthrough])

    on_exit(fn ->
      for mod <- [Settings.MCP, MCP.OAuth2.CredentialsStore] do
        try do
          :meck.unload(mod)
        catch
          _, _ -> :ok
        end
      end
    end)

    # Stub effective_config to return a config containing "srv"
    :meck.expect(Settings.MCP, :effective_config, fn _settings ->
      %{"srv" => %{"command" => "echo"}}
    end)

    :ok
  end

  describe "mcp status" do
    test "displays token info when expires_at is present" do
      now = System.os_time(:second)

      :meck.expect(MCP.OAuth2.CredentialsStore, :read, fn "srv" ->
        {:ok, %{"access_token" => "tok", "expires_at" => now + 300, "last_updated" => now - 10}}
      end)

      log = capture_log(fn -> Status.run(%{}, [:mcp, :status], ["srv"]) end)
      assert log =~ "Token"
      assert log =~ "present"
      assert log =~ "Expires in"
    end

    test "displays 'unknown' when expires_at is nil" do
      now = System.os_time(:second)

      :meck.expect(MCP.OAuth2.CredentialsStore, :read, fn "srv" ->
        {:ok, %{"access_token" => "tok", "expires_at" => nil, "last_updated" => now - 5}}
      end)

      log = capture_log(fn -> Status.run(%{}, [:mcp, :status], ["srv"]) end)
      assert log =~ "Token"
      assert log =~ "present"
      assert log =~ "unknown"
    end

    test "displays 'unknown' when expires_at key is missing" do
      now = System.os_time(:second)

      :meck.expect(MCP.OAuth2.CredentialsStore, :read, fn "srv" ->
        {:ok, %{"access_token" => "tok", "last_updated" => now}}
      end)

      log = capture_log(fn -> Status.run(%{}, [:mcp, :status], ["srv"]) end)
      assert log =~ "unknown"
    end

    test "server not found in config" do
      :meck.expect(Settings.MCP, :effective_config, fn _settings -> %{} end)

      log = capture_log(fn -> Status.run(%{}, [:mcp, :status], ["nope"]) end)
      assert log =~ "Server not found"
    end

    test "no credentials found" do
      :meck.expect(MCP.OAuth2.CredentialsStore, :read, fn "srv" ->
        {:error, :not_found}
      end)

      log = capture_log(fn -> Status.run(%{}, [:mcp, :status], ["srv"]) end)
      assert log =~ "No credentials found"
    end
  end
end

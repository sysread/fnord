defmodule Cmd.Config.MCP.StatusTest do
  use Fnord.TestCase, async: true

  alias Cmd.Config.MCP.Status

  # ---------------------------------------------------------------------------
  # The status command reads real state: server config from the per-test
  # settings file, credentials from the real store under the per-test HOME.
  # Output lands on UI.info/warn/error -> UI.Output.log, captured here by
  # mirroring log traffic to the test process.
  # ---------------------------------------------------------------------------

  setup do
    test_pid = self()

    Mox.stub(UI.Output.Mock, :log, fn _level, msg ->
      send(test_pid, {:log, log_text(msg)})
    end)

    :ok
  end

  defp log_text(msg) do
    IO.iodata_to_binary(msg)
  rescue
    _ -> inspect(msg)
  end

  defp drain_logs(acc \\ []) do
    receive do
      {:log, msg} -> drain_logs([msg | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  defp add_server(name) do
    {:ok, _settings} =
      Settings.MCP.add_server(Settings.new(), :global, name, %{
        "transport" => "stdio",
        "command" => "echo",
        "args" => []
      })

    :ok
  end

  describe "mcp status" do
    test "displays token info when expires_at is present" do
      add_server("srv")
      now = System.os_time(:second)

      :ok =
        MCP.OAuth2.CredentialsStore.write("srv", %{
          "access_token" => "tok",
          "expires_at" => now + 300,
          "last_updated" => now - 10
        })

      Status.run(%{}, [:mcp, :status], ["srv"])

      log = drain_logs()
      assert log =~ "Token"
      assert log =~ "present"
      assert log =~ "Expires in"
    end

    test "displays 'unknown' when expires_at is nil" do
      add_server("srv")
      now = System.os_time(:second)

      :ok =
        MCP.OAuth2.CredentialsStore.write("srv", %{
          "access_token" => "tok",
          "expires_at" => nil,
          "last_updated" => now - 5
        })

      Status.run(%{}, [:mcp, :status], ["srv"])

      log = drain_logs()
      assert log =~ "Token"
      assert log =~ "present"
      assert log =~ "unknown"
    end

    test "displays 'unknown' when expires_at key is missing" do
      add_server("srv")
      now = System.os_time(:second)

      :ok =
        MCP.OAuth2.CredentialsStore.write("srv", %{
          "access_token" => "tok",
          "last_updated" => now
        })

      Status.run(%{}, [:mcp, :status], ["srv"])

      assert drain_logs() =~ "unknown"
    end

    test "server not found in config" do
      Status.run(%{}, [:mcp, :status], ["nope"])

      assert drain_logs() =~ "Server not found"
    end

    test "no credentials found" do
      add_server("srv")

      Status.run(%{}, [:mcp, :status], ["srv"])

      assert drain_logs() =~ "No credentials found"
    end
  end
end

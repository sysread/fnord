defmodule Cmd.Config.MCPTest do
  use Fnord.TestCase, async: false
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  alias Cmd.Config.MCP

  setup do
    File.rm_rf!(Settings.settings_file())
    :ok
  end

  # Enable logger for capturing error messages in tests
  setup do
    old_level = Logger.level()
    Logger.configure(level: :error)
    on_exit(fn -> Logger.configure(level: old_level) end)
    :ok
  end

  describe "mcp list" do
    test "global scope list shows empty servers by default" do
      out = capture_io(fn -> MCP.run(%{global: true}, [:mcp, :list], []) end)
      assert {:ok, %{}} = Jason.decode(out)
    end

    test "project scope without project set errors" do
      log = capture_log(fn -> MCP.run(%{project: "nope"}, [:mcp, :list], []) end)
      assert log =~ "Project not specified or not found"
    end

    test "project scope list when project is set" do
      mock_project("p")
      Settings.set_project("p")
      out = capture_io(fn -> MCP.run(%{}, [:mcp, :list], []) end)
      assert {:ok, %{}} = Jason.decode(out)
    end
  end

  describe "mcp add" do
    test "happy-path adds stdio server with defaults" do
      out =
        capture_io(fn ->
          MCP.run(%{global: true, command: "foo"}, [:mcp, :add], ["srv"])
        end)

      assert {:ok, %{"srv" => cfg}} = Jason.decode(out)
      assert cfg["transport"] == "stdio"
      assert cfg["command"] == "foo"
      assert cfg["args"] == []
      assert cfg["env"] == %{}
    end

    test "adds server with args and env" do
      out =
        capture_io(fn ->
          MCP.run(
            %{global: true, command: "uvx", arg: ["mcp-server-time"], env: ["DEBUG=1"]},
            [:mcp, :add],
            ["time"]
          )
        end)

      assert {:ok, %{"time" => cfg}} = Jason.decode(out)
      assert cfg["transport"] == "stdio"
      assert cfg["command"] == "uvx"
      assert cfg["args"] == ["mcp-server-time"]
      assert cfg["env"] == %{"DEBUG" => "1"}
    end

    test "duplicate add returns error" do
      capture_io(fn ->
        MCP.run(%{global: true, command: "foo"}, [:mcp, :add], ["srv"])
      end)

      log =
        capture_log(fn ->
          MCP.run(%{global: true, command: "foo"}, [:mcp, :add], ["srv"])
        end)

      assert log =~ "Server 'srv' already exists"
    end
  end

  describe "mcp update" do
    setup do
      # add initial server
      capture_io(fn ->
        MCP.run(%{global: true, command: "initial"}, [:mcp, :add], ["foo"])
      end)

      :ok
    end

    test "update non-existent errors" do
      log =
        capture_log(fn ->
          MCP.run(%{global: true, command: "bar"}, [:mcp, :update], ["nope"])
        end)

      assert log =~ "Server 'nope' not found"
    end

    test "update existing server" do
      out =
        capture_io(fn ->
          MCP.run(%{global: true, command: "updated"}, [:mcp, :update], ["foo"])
        end)

      assert {:ok, %{"foo" => %{"command" => "updated"}}} = Jason.decode(out)
    end

    test "update with additional env vars" do
      out =
        capture_io(fn ->
          MCP.run(
            %{global: true, command: "initial", env: ["DEBUG=1", "VERBOSE=true"]},
            [:mcp, :update],
            ["foo"]
          )
        end)

      assert {:ok, %{"foo" => cfg}} = Jason.decode(out)
      assert cfg["env"] == %{"DEBUG" => "1", "VERBOSE" => "true"}
    end
  end

  describe "mcp remove" do
    setup do
      # seed server for removal tests
      capture_io(fn ->
        MCP.run(%{global: true, command: "one"}, [:mcp, :add], ["one"])
      end)

      :ok
    end

    test "remove existing server prints remaining map" do
      out = capture_io(fn -> MCP.run(%{global: true}, [:mcp, :remove], ["one"]) end)
      # The remove command prints the remaining servers map as JSON (empty map)
      assert {:ok, %{}} = Jason.decode(out)
    end

    test "remove non-existent server errors" do
      log = capture_log(fn -> MCP.run(%{global: true}, [:mcp, :remove], ["nope"]) end)
      assert log =~ "Server 'nope' not found"
    end
  end

  describe "mcp check" do
    setup do
      # Mock Services.MCP to avoid actually starting MCP processes
      :meck.new(Services.MCP, [:non_strict])
      :meck.expect(Services.MCP, :start, fn -> :ok end)

      :meck.expect(Services.MCP, :test, fn ->
        %{
          "status" => "ok",
          "servers" => %{
            "test_server" => %{
              "status" => "ok",
              "server_info" => %{"name" => "test_server-server", "status" => "running"},
              "tools" => %{"status" => "error", "error" => ":not_started"}
            }
          }
        }
      end)

      on_exit(fn ->
        try do
          :meck.unload(Services.MCP)
        catch
          _, _ -> :ok
        end
      end)

      # add server for check testing (but don't expect it to actually connect)
      capture_io(fn ->
        MCP.run(%{global: true, command: "echo", arg: ["hello"]}, [:mcp, :add], ["test_server"])
      end)

      :ok
    end

    test "check shows server status" do
      # This will try to connect but fail gracefully - we're just testing the command structure
      out = capture_io(fn -> MCP.run(%{global: true}, [:mcp, :check], []) end)
      assert {:ok, %{"status" => "ok", "servers" => servers}} = Jason.decode(out)
      assert Map.has_key?(servers, "test_server")
    end

    test "check with project scope" do
      # Mock empty response for project scope
      :meck.expect(Services.MCP, :test, fn -> %{"status" => "ok", "servers" => %{}} end)

      mock_project("check_test")
      Settings.set_project("check_test")
      out = capture_io(fn -> MCP.run(%{}, [:mcp, :check], []) end)
      assert {:ok, %{"status" => "ok", "servers" => %{}}} = Jason.decode(out)
    end
  end

  describe "server name handling" do
    test "error when no server name for add" do
      log =
        capture_log(fn ->
          MCP.run(%{global: true}, [:mcp, :add], [])
        end)

      assert log =~ "Server name is required"
    end

    test "error when no server name for update" do
      log =
        capture_log(fn ->
          MCP.run(%{global: true, command: "foo"}, [:mcp, :update], [])
        end)

      assert log =~ "Server name is required"
    end

    test "error when no server name for remove" do
      log =
        capture_log(fn ->
          MCP.run(%{global: true}, [:mcp, :remove], [])
        end)

      assert log =~ "Server name is required"
    end
  end
end

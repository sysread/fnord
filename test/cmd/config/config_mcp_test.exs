defmodule Cmd.Config.MCPTest do
  use Fnord.TestCase, async: false
  import ExUnit.CaptureLog
  alias Cmd.Config.MCP

  # `alias Cmd.Config.MCP` captures the MCP namespace, so the facade mock
  # needs an explicit alias to keep resolving to the top-level module.
  alias Elixir.MCP.Client.Mock, as: MCPClientMock

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
      {out, _stderr} = capture_all(fn -> MCP.run(%{global: true}, [:mcp, :list], []) end)
      assert {:ok, %{}} = SafeJson.decode(out)
    end

    test "project scope without project set errors" do
      log = capture_log(fn -> MCP.run(%{project: "nope"}, [:mcp, :list], []) end)
      assert log =~ "Project not specified or not found"
    end

    test "project scope list when project is set" do
      mock_project("p")
      Settings.set_project("p")
      {out, _stderr} = capture_all(fn -> MCP.run(%{}, [:mcp, :list], []) end)
      assert {:ok, %{}} = SafeJson.decode(out)
    end
  end

  describe "mcp add" do
    test "happy-path adds stdio server with defaults" do
      {out, _stderr} =
        capture_all(fn ->
          MCP.run(%{global: true, command: "foo"}, [:mcp, :add], ["srv"])
        end)

      assert {:ok, %{"srv" => cfg}} = SafeJson.decode(out)
      assert cfg["transport"] == "stdio"
      assert cfg["command"] == "foo"
      assert cfg["args"] == []
      assert cfg["env"] == %{}
    end

    test "adds server with args and env" do
      {out, _stderr} =
        capture_all(fn ->
          MCP.run(
            %{global: true, command: "uvx", arg: ["mcp-server-time"], env: ["DEBUG=1"]},
            [:mcp, :add],
            ["time"]
          )
        end)

      assert {:ok, %{"time" => cfg}} = SafeJson.decode(out)
      assert cfg["transport"] == "stdio"
      assert cfg["command"] == "uvx"
      assert cfg["args"] == ["mcp-server-time"]
      assert cfg["env"] == %{"DEBUG" => "1"}
    end

    test "duplicate add returns error" do
      {_stdout, _stderr} =
        capture_all(fn ->
          MCP.run(%{global: true, command: "foo"}, [:mcp, :add], ["srv"])
        end)

      log =
        capture_log(fn ->
          MCP.run(%{global: true, command: "foo"}, [:mcp, :add], ["srv"])
        end)

      assert log =~ "Server already exists"
    end
  end

  describe "mcp update" do
    setup do
      # add initial server
      {_stdout, _stderr} =
        capture_all(fn ->
          MCP.run(%{global: true, command: "initial"}, [:mcp, :add], ["foo"])
        end)

      :ok
    end

    test "update non-existent errors" do
      log =
        capture_log(fn ->
          MCP.run(%{global: true, command: "bar"}, [:mcp, :update], ["nope"])
        end)

      assert log =~ "Server not found"
    end

    test "update existing server" do
      {out, _stderr} =
        capture_all(fn ->
          MCP.run(%{global: true, command: "updated"}, [:mcp, :update], ["foo"])
        end)

      assert {:ok, %{"foo" => %{"command" => "updated"}}} = SafeJson.decode(out)
    end

    test "update with additional env vars" do
      {out, _stderr} =
        capture_all(fn ->
          MCP.run(
            %{global: true, command: "initial", env: ["DEBUG=1", "VERBOSE=true"]},
            [:mcp, :update],
            ["foo"]
          )
        end)

      assert {:ok, %{"foo" => cfg}} = SafeJson.decode(out)
      assert cfg["env"] == %{"DEBUG" => "1", "VERBOSE" => "true"}
    end
  end

  describe "mcp remove" do
    setup do
      # seed server for removal tests
      {_stdout, _stderr} =
        capture_all(fn ->
          MCP.run(%{global: true, command: "one"}, [:mcp, :add], ["one"])
        end)

      :ok
    end

    test "remove existing server prints remaining map" do
      {out, _stderr} = capture_all(fn -> MCP.run(%{global: true}, [:mcp, :remove], ["one"]) end)
      # The remove command prints the remaining servers map as JSON (empty map)
      assert {:ok, %{}} = SafeJson.decode(out)
    end

    test "remove non-existent server errors" do
      log = capture_log(fn -> MCP.run(%{global: true}, [:mcp, :remove], ["nope"]) end)
      assert log =~ "Server not found"
    end
  end

  describe "mcp check" do
    setup do
      # The check command boots MCP and runs discovery for real; the Hermes
      # runtime is scripted through the MCP.Client facade so no server
      # process is ever spawned.
      mock_mcp_client()
      :ok
    end

    test "check shows server status" do
      {_stdout, _stderr} =
        capture_all(fn ->
          MCP.run(%{global: true, command: "echo", arg: ["hello"]}, [:mcp, :add], ["test_server"])
        end)

      Mox.stub(MCPClientMock, :connected?, fn "test_server" -> true end)

      Mox.stub(MCPClientMock, :list_tools, fn "test_server" ->
        {:ok, [%{"name" => "test_tool", "description" => "A test tool"}]}
      end)

      Mox.stub(MCPClientMock, :get_server_capabilities, fn "test_server" ->
        {:ok, %{"tools" => %{}}}
      end)

      {out, _stderr} = capture_all(fn -> MCP.run(%{global: true}, [:mcp, :check], []) end)
      assert out =~ "Checking MCP servers"
      assert out =~ "test_server"
      assert out =~ "Connection"
      assert out =~ "Tools"
    end

    test "check with project scope" do
      mock_project("check_test")
      Settings.set_project("check_test")
      {out, _stderr} = capture_all(fn -> MCP.run(%{}, [:mcp, :check], []) end)
      assert out =~ "No MCP servers configured"
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

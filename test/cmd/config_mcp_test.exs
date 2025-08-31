defmodule Cmd.ConfigMCPTest do
  use Fnord.TestCase
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
    test "effective on empty prints disabled/empty" do
      out = capture_io(fn -> MCP.run(%{effective: true}, [:mcp, :list], []) end)
      assert {:ok, %{"enabled" => false, "servers" => %{}}} = Jason.decode(out)
    end

    test "global scope list reflects Settings.MCP.get_config/1" do
      out1 = capture_io(fn -> MCP.run(%{global: true}, [:mcp, :list], []) end)
      assert {:ok, %{"enabled" => false, "servers" => %{}}} = Jason.decode(out1)
      # toggle
      capture_io(fn -> MCP.run(%{global: true}, [:mcp, :enable], []) end)
      out2 = capture_io(fn -> MCP.run(%{global: true}, [:mcp, :list], []) end)
      assert {:ok, %{"enabled" => true, "servers" => %{}}} = Jason.decode(out2)
    end

    test "project scope without project set errors" do
      log = capture_log(fn -> MCP.run(%{project: "nope"}, [:mcp, :list], []) end)
      assert log =~ "Project not specified or not found"
    end

    test "project scope list when project is set" do
      mock_project("p")
      Settings.set_project("p")
      out = capture_io(fn -> MCP.run(%{}, [:mcp, :list], []) end)
      assert {:ok, %{"enabled" => false, "servers" => %{}}} = Jason.decode(out)
    end
  end

  describe "mcp enable/disable" do
    test "toggle global" do
      en = capture_io(fn -> MCP.run(%{global: true}, [:mcp, :enable], []) end)
      dis = capture_io(fn -> MCP.run(%{global: true}, [:mcp, :disable], []) end)
      assert {:ok, %{"enabled" => true, "servers" => %{}}} = Jason.decode(en)
      assert {:ok, %{"enabled" => false, "servers" => %{}}} = Jason.decode(dis)
    end

    test "toggle project" do
      mock_project("x")
      Settings.set_project("x")
      en = capture_io(fn -> MCP.run(%{}, [:mcp, :enable], []) end)
      assert {:ok, %{"enabled" => true, "servers" => %{}}} = Jason.decode(en)
      dis = capture_io(fn -> MCP.run(%{}, [:mcp, :disable], []) end)
      assert {:ok, %{"enabled" => false, "servers" => %{}}} = Jason.decode(dis)
    end
  end

  describe "mcp add" do
    test "happy-path adds stdio server with defaults" do
      out =
        capture_io(fn ->
          MCP.run(%{global: true, transport: "stdio", command: "foo"}, [:mcp, :add], ["srv"])
        end)

      assert {:ok, %{"srv" => cfg}} = Jason.decode(out)
      assert cfg["transport"] == "stdio"
      assert cfg["command"] == "foo"
      assert cfg["args"] == []
      assert cfg["env"] == %{}
    end

    test "duplicate add returns error" do
      capture_io(fn ->
        MCP.run(%{global: true, transport: "stdio", command: "foo"}, [:mcp, :add], ["srv"])
      end)

      log =
        capture_log(fn ->
          MCP.run(%{global: true, transport: "stdio", command: "foo"}, [:mcp, :add], ["srv"])
        end)

      assert log =~ "Server 'srv' already exists"
    end
  end

  describe "mcp update" do
    setup do
      # add initial server
      capture_io(fn ->
        MCP.run(%{global: true, transport: "stdio", command: "initial"}, [:mcp, :add], ["foo"])
      end)

      :ok
    end

    test "update non-existent errors" do
      log =
        capture_log(fn ->
          MCP.run(%{global: true, transport: "stdio", command: "bar"}, [:mcp, :update], ["nope"])
        end)

      assert log =~ "Server 'nope' not found"
    end

    test "update existing server" do
      out =
        capture_io(fn ->
          MCP.run(%{global: true, transport: "stdio", command: "updated"}, [:mcp, :update], [
            "foo"
          ])
        end)

      assert {:ok, %{"foo" => %{"command" => "updated"}}} = Jason.decode(out)
    end
  end

  describe "mcp remove" do
    setup do
      # seed server for removal tests
      capture_io(fn ->
        MCP.run(%{global: true, transport: "stdio", command: "one"}, [:mcp, :add], ["one"])
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

  describe "mcp commands via opts[:name]" do
    test "add via opts" do
      out =
        capture_io(fn ->
          MCP.run(
            %{global: true, name: "srv", transport: "stdio", command: "foo"},
            [:mcp, :add],
            []
          )
        end)

      assert {:ok, %{"srv" => _}} = Jason.decode(out)
    end

    test "error when no server name" do
      log =
        capture_log(fn ->
          MCP.run(%{global: true}, [:mcp, :add], [])
        end)

      assert log =~ "Server name is required"
    end

    test "update via opts" do
      # seed initial server for update
      capture_io(fn ->
        MCP.run(
          %{global: true, name: "foo", transport: "stdio", command: "initial"},
          [:mcp, :add],
          []
        )
      end)

      out =
        capture_io(fn ->
          MCP.run(
            %{global: true, name: "foo", transport: "stdio", command: "updated"},
            [:mcp, :update],
            []
          )
        end)

      assert {:ok, %{"foo" => %{"command" => "updated"}}} = Jason.decode(out)
    end

    test "error when no server name for update" do
      log =
        capture_log(fn ->
          MCP.run(
            %{global: true, transport: "stdio", command: "foo"},
            [:mcp, :update],
            []
          )
        end)

      assert log =~ "Server name is required"
    end

    test "remove via opts" do
      # seed server for removal
      capture_io(fn ->
        MCP.run(
          %{global: true, name: "foo", transport: "stdio", command: "init"},
          [:mcp, :add],
          []
        )
      end)

      out =
        capture_io(fn ->
          MCP.run(
            %{global: true, name: "foo"},
            [:mcp, :remove],
            []
          )
        end)

      assert {:ok, %{}} = Jason.decode(out)
    end

    test "error when no server name for remove" do
      log =
        capture_log(fn ->
          MCP.run(
            %{global: true},
            [:mcp, :remove],
            []
          )
        end)

      assert log =~ "Server name is required"
    end
  end
end

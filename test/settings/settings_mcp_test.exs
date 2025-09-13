defmodule Settings.MCPTest do
  use Fnord.TestCase

  alias Settings.MCP

  describe "default configuration" do
    test "global get_config returns empty map with no servers" do
      settings = Settings.new()
      assert MCP.get_config(settings, :global) == %{}
      assert MCP.list_servers(settings, :global) == %{}
    end
  end

  describe "adding servers" do
    setup do
      %{settings: Settings.new()}
    end

    test "error when missing command for stdio transport", %{settings: settings} do
      assert {:error, msg} = MCP.add_server(settings, :global, "foo", %{"transport" => "stdio"})
      assert msg =~ "Missing 'command'"
    end

    test "successfully add valid stdio server", %{settings: settings} do
      cfg = %{"transport" => "stdio", "command" => "run.sh"}
      assert {:ok, settings2} = MCP.add_server(settings, :global, "foo", cfg)

      servers = MCP.list_servers(settings2, :global)
      assert Map.has_key?(servers, "foo")
      server = servers["foo"]
      assert server["transport"] == "stdio"
      assert server["command"] == "run.sh"
      assert server["args"] == []
      assert server["env"] == %{}
      refute Map.has_key?(server, "timeout_ms")
    end

    test "duplicate add returns exists error", %{settings: settings} do
      cfg = %{"transport" => "stdio", "command" => "run.sh"}
      {:ok, settings2} = MCP.add_server(settings, :global, "foo", cfg)
      assert {:error, :exists} = MCP.add_server(settings2, :global, "foo", cfg)
    end
  end

  describe "updating and removing servers" do
    setup do
      settings = Settings.new()
      cfg0 = %{"transport" => "stdio", "command" => "first"}
      {:ok, settings} = MCP.add_server(settings, :global, "srv", cfg0)
      %{settings: settings}
    end

    test "remove_server deletes entry", %{settings: settings} do
      assert {:ok, settings2} = MCP.remove_server(settings, :global, "srv")
      assert MCP.list_servers(settings2, :global) == %{}
    end

    test "update_server errors when not present", %{settings: settings} do
      cfg = %{"transport" => "stdio", "command" => "new"}
      assert {:error, :not_found} = MCP.update_server(settings, :global, "unknown", cfg)
    end

    test "update_server replaces existing config", %{settings: settings} do
      cfg = %{"transport" => "stdio", "command" => "updated"}
      assert {:ok, settings2} = MCP.update_server(settings, :global, "srv", cfg)

      servers = MCP.list_servers(settings2, :global)
      assert servers["srv"]["command"] == "updated"
    end
  end
end

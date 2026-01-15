defmodule Settings.MCPTest do
  use Fnord.TestCase, async: false

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

  describe "server config validation" do
    test "error when missing or invalid transport" do
      settings = Settings.new()
      assert {:error, msg} = MCP.add_server(settings, :global, "foo", %{})
      assert msg =~ "Missing or invalid 'transport'"
    end

    test "error when http transport missing base_url" do
      settings = Settings.new()
      cfg = %{"transport" => "http"}
      assert {:error, msg} = MCP.add_server(settings, :global, "foo", cfg)
      assert msg =~ "Missing 'base_url' for http transport"
    end

    test "error when websocket transport with non-map headers" do
      settings = Settings.new()

      cfg = %{
        "transport" => "websocket",
        "base_url" => "ws://example",
        "headers" => ["not", "a", "map"]
      }

      assert {:error, msg} = MCP.add_server(settings, :global, "foo", cfg)
      assert msg =~ "Invalid 'headers' for websocket transport"
    end

    test "error when stdio transport with non-list args" do
      settings = Settings.new()
      cfg = %{"transport" => "stdio", "command" => "cmd", "args" => "notalist"}
      assert {:error, msg} = MCP.add_server(settings, :global, "foo", cfg)
      assert msg =~ "Invalid 'args' or 'env' for stdio transport"
    end

    test "timeout_ms normalization strips invalid values" do
      settings = Settings.new()
      cfg1 = %{"transport" => "stdio", "command" => "cmd", "timeout_ms" => -100}
      cfg2 = %{"transport" => "stdio", "command" => "cmd", "timeout_ms" => "abc"}
      {:ok, settings1} = MCP.add_server(settings, :global, "foo", cfg1)
      {:ok, settings2} = MCP.add_server(settings1, :global, "bar", cfg2)
      servers = MCP.list_servers(settings2, :global)
      refute Map.has_key?(servers["foo"], "timeout_ms")
      refute Map.has_key?(servers["bar"], "timeout_ms")
    end
  end

  describe "oauth normalization" do
    test "accepts valid oauth map" do
      settings = Settings.new()

      oauth = %{
        "discovery_url" => "http://discovery",
        "client_id" => "id",
        "scopes" => ["scope1", "scope2"],
        "client_secret" => "secret",
        "refresh_margin" => 30
      }

      cfg = %{"transport" => "stdio", "command" => "cmd", "oauth" => oauth}
      {:ok, settings2} = MCP.add_server(settings, :global, "foo", cfg)
      server = MCP.list_servers(settings2, :global)["foo"]
      assert server["oauth"] == oauth
    end

    test "error on invalid oauth type" do
      settings = Settings.new()
      cfg = %{"transport" => "stdio", "command" => "cmd", "oauth" => "nope"}
      assert {:ok, settings2} = MCP.add_server(settings, :global, "foo", cfg)
      server = MCP.list_servers(settings2, :global)["foo"]
      refute Map.has_key?(server, "oauth")
    end

    test "error on oauth map missing required fields" do
      settings = Settings.new()
      cfg = %{"transport" => "stdio", "command" => "cmd", "oauth" => %{"client_id" => "id"}}
      assert {:ok, settings2} = MCP.add_server(settings, :global, "foo", cfg)
      server = MCP.list_servers(settings2, :global)["foo"]
      refute Map.has_key?(server, "oauth")
    end

    test "error on invalid oauth scopes type" do
      settings = Settings.new()

      oauth = %{
        "client_id" => "id",
        "client_secret" => "secret",
        "token_url" => "http://token",
        "scopes" => [1]
      }

      cfg = %{"transport" => "stdio", "command" => "cmd", "oauth" => oauth}
      assert {:ok, settings2} = MCP.add_server(settings, :global, "foo", cfg)
      server = MCP.list_servers(settings2, :global)["foo"]
      refute Map.has_key?(server, "oauth")
    end
  end
end

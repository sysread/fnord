defmodule Services.MCPTest do
  use Fnord.TestCase, async: false

  setup do
    # Stub effective_config to simulate two servers
    :meck.new(Settings.MCP, [:non_strict])

    :meck.expect(Settings.MCP, :effective_config, fn _settings ->
      %{"enabled" => true, "servers" => %{"srv1" => %{}, "srv2" => %{}}}
    end)

    on_exit(fn ->
      try do
        :meck.unload(Settings.MCP)
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  test "test/0 returns success for all servers when client returns ok" do
    # Define a stub client that always returns success
    defmodule StubClientSuccess do
      def list_tools(_instance) do
        {:ok, [%{"name" => "toolX", "description" => "descX"}]}
      end

      def get_server_info(_instance) do
        {:ok, %{"uptime" => 42}}
      end
    end

    # Configure Services.MCP to use our stub client
    set_config(:mcp_client_mod, StubClientSuccess)

    result = Services.MCP.test()

    # The overall status should be ok
    assert %{status: "ok", servers: servers} = result
    # Both servers should report status ok with tool blurb
    for srv <- ["srv1", "srv2"] do
      assert %{status: "ok", tools: [%{"name" => "toolX", "description" => "descX"}]} =
               servers[srv]
    end
  end

  test "test/0 reports error when client returns error" do
    # Define a stub client that returns errors
    defmodule StubClientError do
      def list_tools(_instance), do: {:error, "list_error"}
      def get_server_info(_instance), do: {:error, "info_error"}
    end

    set_config(:mcp_client_mod, StubClientError)

    result = Services.MCP.test()

    # Overall status remains ok but individual servers have error entries
    assert %{status: "ok", servers: servers} = result

    for srv <- ["srv1", "srv2"] do
      # The tools branch error should be reflected
      assert %{status: "error", error: "list_error"} = servers[srv]
    end
  end
end

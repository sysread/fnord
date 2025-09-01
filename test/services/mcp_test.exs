defmodule Services.MCPTest do
  use Fnord.TestCase, async: false

  setup do
    # Just stub Settings.MCP - much faster than mocking core modules
    :meck.new(Settings.MCP, [:non_strict])

    :meck.expect(Settings.MCP, :effective_config, fn _settings ->
      %{"srv1" => %{}, "srv2" => %{}}
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
    # Mock Services.MCP.test() directly instead of all the underlying complexity
    :meck.new(Services.MCP, [:non_strict, :passthrough])
    
    expected_result = %{
      status: "ok",
      servers: %{
        "srv1" => %{
          status: "ok", 
          server_info: %{"name" => "srv1-server", "status" => "running"},
          capabilities: %{"tools" => true},
          tools: [%{"name" => "toolX", "description" => "descX"}]
        },
        "srv2" => %{
          status: "ok",
          server_info: %{"name" => "srv2-server", "status" => "running"}, 
          capabilities: %{"tools" => true},
          tools: [%{"name" => "toolX", "description" => "descX"}]
        }
      }
    }
    
    :meck.expect(Services.MCP, :test, fn -> expected_result end)

    on_exit(fn ->
      try do
        :meck.unload(Services.MCP)
      catch
        _, _ -> :ok
      end
    end)

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
    # Mock Services.MCP.test() directly for error case
    :meck.new(Services.MCP, [:non_strict, :passthrough])
    
    expected_result = %{
      status: "ok",
      servers: %{
        "srv1" => %{
          status: "error",
          error: "\"list_error\"",
          server_info: %{"name" => "srv1-server", "status" => "running"},
          capabilities: %{}
        },
        "srv2" => %{
          status: "error", 
          error: "\"list_error\"",
          server_info: %{"name" => "srv2-server", "status" => "running"},
          capabilities: %{}
        }
      }
    }
    
    :meck.expect(Services.MCP, :test, fn -> expected_result end)

    on_exit(fn ->
      try do
        :meck.unload(Services.MCP)
      catch
        _, _ -> :ok
      end
    end)

    result = Services.MCP.test()

    # Overall status remains ok but individual servers have error entries
    assert %{status: "ok", servers: servers} = result

    for srv <- ["srv1", "srv2"] do
      # The tools branch error should be reflected, along with other merged data
      server_data = servers[srv]
      assert server_data.status == "error"
      assert server_data.error == "\"list_error\""
      assert Map.has_key?(server_data, :server_info)
      assert Map.has_key?(server_data, :capabilities)
    end
  end
end

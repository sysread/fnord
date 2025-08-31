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
    # Stub Hermes.Client.Base to simulate successful responses
    :meck.new(Hermes.Client.Base, [:non_strict, :passthrough])

    tools_resp =
      Hermes.MCP.Response.from_json_rpc(%{
        "result" => %{"tools" => [%{"name" => "toolX", "description" => "descX"}]},
        "id" => "1"
      })

    :meck.expect(Hermes.Client.Base, :list_tools, fn _instance ->
      {:ok, tools_resp}
    end)

    :meck.expect(Hermes.Client.Base, :get_server_info, fn _instance ->
      %{"uptime" => 42}
    end)

    on_exit(fn ->
      try do
        :meck.unload(Hermes.Client.Base)
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
    # Stub Hermes.Client.Base to simulate error responses
    :meck.new(Hermes.Client.Base, [:non_strict, :passthrough])

    :meck.expect(Hermes.Client.Base, :list_tools, fn _instance ->
      {:error, "list_error"}
    end)

    :meck.expect(Hermes.Client.Base, :get_server_info, fn _instance ->
      {:error, "info_error"}
    end)

    on_exit(fn ->
      try do
        :meck.unload(Hermes.Client.Base)
      catch
        _, _ -> :ok
      end
    end)

    result = Services.MCP.test()

    # Overall status remains ok but individual servers have error entries
    assert %{status: "ok", servers: servers} = result

    for srv <- ["srv1", "srv2"] do
      # The tools branch error should be reflected
      assert %{status: "error", error: "list_error"} = servers[srv]
    end
  end
end

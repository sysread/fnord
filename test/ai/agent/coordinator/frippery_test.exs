defmodule AI.Agent.Coordinator.FripperyTest do
  use Fnord.TestCase, async: false

  describe "log_available_mcp_tools/0" do
    setup do
      mock_project("coordinator_frippery")
      :ok
    end

    test "groups MCP tools by service and sorts services and tool names" do
      :ok =
        MCP.Tools.register_server_tools("zeta", [
          %{"name" => "zap", "description" => "", "inputSchema" => %{}}
        ])

      :ok =
        MCP.Tools.register_server_tools("foo", [
          %{"name" => "baz", "description" => "", "inputSchema" => %{}},
          %{"name" => "bar", "description" => "", "inputSchema" => %{}},
          %{"name" => "bat", "description" => "", "inputSchema" => %{}}
        ])

      expect(UI.Output.Mock, :log, fn level, msg ->
        rendered = IO.iodata_to_binary(msg)

        assert level == :info
        assert rendered == "MCP tools: \nfoo( bar | bat | baz )\nzeta( zap )"
        :ok
      end)

      AI.Agent.Coordinator.Frippery.log_available_mcp_tools()
    end
  end
end

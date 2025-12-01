defmodule AI.Agent.TersifierTest do
  use Fnord.TestCase, async: false

  @moduletag :capture_log

  test "returns original content when message content is empty or non-binary" do
    agent = AI.Agent.new(AI.Agent.Tersifier, named?: false)

    assert {:ok, ""} = AI.Agent.get_response(agent, %{message: %{role: "assistant", content: ""}})
    assert {:ok, ""} = AI.Agent.get_response(agent, %{message: %{role: "assistant"}})
  end

  test "can be invoked without raising for a simple assistant message" do
    agent = AI.Agent.new(AI.Agent.Tersifier, named?: false)

    {:ok, result} =
      AI.Agent.get_response(agent, %{
        message: %{role: "assistant", content: "Explain this code in detail"}
      })

    assert is_binary(result)
    assert result != nil
  end
end

defmodule AI.Agent.ConversationQATest do
  use Fnord.TestCase, async: false

  alias AI.Agent.ConversationQA

  setup do
    {:ok, project: mock_project("conversation_qa_test")}
  end

  test "returns error for missing conversation" do
    agent = AI.Agent.new(ConversationQA, [])

    assert {:error, :conversation_not_found} =
             ConversationQA.get_response(%{
               agent: agent,
               conversation_id: "missing",
               question: "What happened?"
             })
  end
end

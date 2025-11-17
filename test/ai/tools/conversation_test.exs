defmodule AI.Tools.ConversationTest do
  use Fnord.TestCase, async: false

  alias AI.Tools.Conversation

  setup do
    {:ok, project: mock_project("conversation_tool_test")}
  end

  test "search action delegates to Search.Conversations" do
    Services.Globals.put_env(:fnord, :indexer, StubIndexer)

    {:ok, results} =
      Conversation.call(%{"action" => "search", "query" => "foo", "limit" => 5})

    assert is_list(results)
  end

  test "ask action delegates to ConversationQA agent" do
    Services.Globals.put_env(:fnord, :indexer, StubIndexer)

    assert {:error, _reason} = Conversation.call(%{"action" => "ask", "question" => "hi"})
  end
end

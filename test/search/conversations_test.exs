defmodule Search.ConversationsTest do
  use Fnord.TestCase, async: false

  alias Store.Project.Conversation
  alias Store.Project.ConversationIndex

  setup do
    {:ok, project: mock_project("search_conversations_test")}
  end

  test "search/3 returns ranked conversations", %{project: project} do
    # Create two conversations with embeddings
    convo1 = Conversation.new("one", project)
    convo2 = Conversation.new("two", project)

    messages = [AI.Util.user_msg("topic alpha")]
    {:ok, _} = Conversation.write(convo1, messages)
    {:ok, _} = Conversation.write(convo2, messages)

    # Set embeddings with 3-element vectors to match StubIndexer
    ConversationIndex.write_embeddings(project, convo1.id, [1.0, 2.0, 3.0], %{
      "last_indexed_ts" => 1
    })

    ConversationIndex.write_embeddings(project, convo2.id, [3.0, 2.0, 1.0], %{
      "last_indexed_ts" => 1
    })

    Services.Globals.put_env(:fnord, :indexer, StubIndexer)

    {:ok, results} = Search.Conversations.search(project, "alpha", limit: 2)

    assert is_list(results)
    assert Enum.all?(results, &Map.has_key?(&1, :conversation_id))

    timestamps =
      results
      |> Enum.map(fn %{conversation_id: id} ->
        conv = Conversation.new(id, project)
        case Conversation.timestamp(conv) do
          %DateTime{} = dt -> DateTime.to_unix(dt)
          _ -> 0
        end
      end)

    assert timestamps == Enum.sort(timestamps, :desc)
  end
end

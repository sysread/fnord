defmodule Services.Conversation.IndexerTest do
  # Sync: the indexer is started by the test rather than the instance roster
  # and begins processing immediately, so async Mox allowances cannot be
  # granted to it before it needs them. Global mode sidesteps that.
  use Fnord.TestCase, async: false

  setup do
    # Embeddings go through the default MockIndexer stub; the conversation
    # summarizer is canned at the agent-dispatch seam so it doesn't hit the
    # real LLM.
    canned_agent(fn AI.Agent.ConversationSummary, _args ->
      {:ok, "test summary"}
    end)

    {:ok, project: mock_project("conv_indexer_test")}
  end

  test "indexes queued conversations then stops cleanly", %{project: project} do
    convo1 = Store.Project.Conversation.new("one", project)
    convo2 = Store.Project.Conversation.new("two", project)

    messages = [AI.Util.system_msg("hello")]

    {:ok, _} =
      Store.Project.Conversation.write(convo1, %{messages: messages, metadata: %{}, memories: []})

    {:ok, _} =
      Store.Project.Conversation.write(convo2, %{messages: messages, metadata: %{}, memories: []})

    {:ok, pid} =
      Services.ConversationIndexer.start_link(project: project, conversations: [convo1, convo2])

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

    embeddings =
      Store.Project.ConversationIndex.all_embeddings(project)
      |> Enum.into([])

    assert Enum.any?(embeddings, fn {id, _emb, _meta} -> id == convo1.id end)
    assert Enum.any?(embeddings, fn {id, _emb, _meta} -> id == convo2.id end)
  end

  test "does not process queued conversations when embeddings model is paused", %{
    project: project
  } do
    convo1 = Store.Project.Conversation.new("one", project)
    convo2 = Store.Project.Conversation.new("two", project)

    messages = [AI.Util.system_msg("hello")]

    {:ok, _} =
      Store.Project.Conversation.write(convo1, %{messages: messages, metadata: %{}, memories: []})

    {:ok, _} =
      Store.Project.Conversation.write(convo2, %{messages: messages, metadata: %{}, memories: []})

    Services.BgIndexingControl.pause("embeddings")
    on_exit(fn -> Services.BgIndexingControl.clear_pause("embeddings") end)

    {:ok, pid} =
      Services.ConversationIndexer.start_link(project: project, conversations: [convo1, convo2])

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 2_000
    assert reason in [:normal, :noproc]

    # Nothing may have been written to the index while paused.
    embeddings =
      Store.Project.ConversationIndex.all_embeddings(project)
      |> Enum.into([])

    assert embeddings == []
  end
end

defmodule Services.ConversationIndexerTest do
  use Fnord.TestCase, async: false

  alias Services.ConversationIndexer

  defmodule StubIndexer do
    use Agent
    @behaviour Indexer

    def start_link(_opts) do
      Agent.start_link(fn -> MapSet.new() end, name: __MODULE__)
    end

    def reset do
      Agent.update(__MODULE__, fn _ -> MapSet.new() end)
    end

    def processed?(id), do: Agent.get(__MODULE__, &MapSet.member?(&1, id))

    @impl Indexer
    def get_embeddings(_content), do: {:ok, []}

    @impl Indexer
    def get_summary(_file, _content), do: {:ok, "summary"}

    @impl Indexer
    def get_outline(_file, _content), do: {:ok, "outline"}
  end

  setup do
    Services.Globals.put_env(:fnord, :indexer, StubIndexer)
    {:ok, _} = StubIndexer.start_link([])
    StubIndexer.reset()

    {:ok, project: mock_project("conv_indexer_test")}
  end

  test "indexes queued conversations then stops cleanly", %{project: project} do
    convo1 = Store.Project.Conversation.new("one", project)
    convo2 = Store.Project.Conversation.new("two", project)

    messages = [AI.Util.system_msg("hello")]
    {:ok, _} = Store.Project.Conversation.write(convo1, %{messages: messages, metadata: %{}, memories: []})
    {:ok, _} = Store.Project.Conversation.write(convo2, %{messages: messages, metadata: %{}, memories: []})

    {:ok, pid} = ConversationIndexer.start_link(project: project, conversations: [convo1, convo2])
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

    embeddings =
      Store.Project.ConversationIndex.all_embeddings(project)
      |> Enum.into([])

    assert Enum.any?(embeddings, fn {id, _emb, _meta} -> id == convo1.id end)
    assert Enum.any?(embeddings, fn {id, _emb, _meta} -> id == convo2.id end)
  end
end

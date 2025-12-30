defmodule Store.Project.ConversationIndexTest do
  use Fnord.TestCase, async: false

  alias Store.Project.Conversation
  alias Store.Project.ConversationIndex

  setup do
    {:ok, project: mock_project("conv_index_test")}
  end

  test "root/1 and path_for/2 build expected paths", %{project: project} do
    id = "DEADBEEF"

    expected_root = Path.join(project.store_path, "conversations/index")
    assert ConversationIndex.root(project) == expected_root

    expected_path = Path.join(expected_root, id)
    assert ConversationIndex.path_for(project, id) == expected_path
  end

  test "write_embeddings/4 and read_embeddings/2 roundtrip", %{project: project} do
    convo = Conversation.new("roundtrip", project)

    # ensure conversations dir exists so list/1 can find it if needed later
    File.mkdir_p!(Path.dirname(convo.store_path))

    embeddings = [0.1, 0.2, 0.3]
    metadata = %{"last_indexed_ts" => 1234, "embedding_model" => "test-model"}

    assert :ok = ConversationIndex.write_embeddings(project, convo.id, embeddings, metadata)

    assert {:ok, %{embeddings: ^embeddings, metadata: ^metadata}} =
             ConversationIndex.read_embeddings(project, convo.id)
  end

  test "all_embeddings/1 enumerates indexed conversations", %{project: project} do
    convo1 = Conversation.new("one", project)
    convo2 = Conversation.new("two", project)

    File.mkdir_p!(Path.dirname(convo1.store_path))

    assert :ok =
             ConversationIndex.write_embeddings(project, convo1.id, [1.0], %{
               "last_indexed_ts" => 1
             })

    assert :ok =
             ConversationIndex.write_embeddings(project, convo2.id, [2.0], %{
               "last_indexed_ts" => 2
             })

    all = ConversationIndex.all_embeddings(project) |> Enum.into([])

    assert {convo1.id, [1.0], %{"last_indexed_ts" => 1}} in all
    assert {convo2.id, [2.0], %{"last_indexed_ts" => 2}} in all
  end

  test "delete/2 removes index directory", %{project: project} do
    convo = Conversation.new("todelete", project)

    File.mkdir_p!(Path.dirname(convo.store_path))

    assert :ok =
             ConversationIndex.write_embeddings(project, convo.id, [0.5], %{
               "last_indexed_ts" => 10
             })

    dir = ConversationIndex.path_for(project, convo.id)
    assert File.dir?(dir)

    assert :ok = ConversationIndex.delete(project, convo.id)
    refute File.exists?(dir)
  end

  test "index_status/1 reports new, stale, and deleted conversations", %{project: project} do
    # Create conversations on disk by writing simple JSON files
    conv_dir = Path.join(project.store_path, "conversations")
    File.mkdir_p!(conv_dir)

    # conv_new: exists but no index yet
    conv_new_id = "conv_new"
    conv_new_path = Path.join(conv_dir, conv_new_id <> ".json")
    File.write!(conv_new_path, "100:{\"messages\":[]}")

    # conv_stale: has an index entry with older last_indexed_ts
    conv_stale_id = "conv_stale"
    conv_stale_path = Path.join(conv_dir, conv_stale_id <> ".json")
    File.write!(conv_stale_path, "200:{\"messages\":[]}")

    # conv_deleted_index: has an index entry but no conversation file
    conv_deleted_id = "conv_deleted"

    # write index entries
    index_root = ConversationIndex.root(project)

    for {id, ts} <- [{conv_stale_id, 100}, {conv_deleted_id, 50}] do
      dir = Path.join(index_root, id)
      File.mkdir_p!(dir)

      :ok =
        File.write!(
          Path.join(dir, "metadata.json"),
          Jason.encode!(%{"last_indexed_ts" => ts})
        )

      :ok =
        File.write!(
          Path.join(dir, "embeddings.json"),
          Jason.encode!([0.0])
        )
    end

    status = ConversationIndex.index_status(project)

    # new: conv_new only
    assert [%Conversation{id: ^conv_new_id}] = status.new

    # stale: conv_stale only
    assert [%Conversation{id: ^conv_stale_id}] = status.stale

    # deleted: conv_deleted only
    assert [^conv_deleted_id] = status.deleted
  end

  test "metadata-only conversation write does not make an indexed conversation stale", %{
    project: project
  } do
    convo = Conversation.new("meta_only", project)

    {:ok, _} =
      Conversation.write(convo, %{
        messages: [AI.Util.user_msg("hello")],
        metadata: %{},
        memory: []
      })

    {:ok, data} = Conversation.read(convo)
    ts = DateTime.to_unix(data.timestamp)

    :ok = ConversationIndex.write_embeddings(project, convo.id, [0.0], %{"last_indexed_ts" => ts})

    status = ConversationIndex.index_status(project)
    assert [] == Enum.filter(status.stale, &(&1.id == convo.id))
    assert [] == Enum.filter(status.new, &(&1.id == convo.id))

    {:ok, _} = Conversation.write(convo, %{metadata: %{foo: "bar"}})

    status = ConversationIndex.index_status(project)
    assert [] == Enum.filter(status.stale, &(&1.id == convo.id))
    assert [] == Enum.filter(status.new, &(&1.id == convo.id))
  end
end

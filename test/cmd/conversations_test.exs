defmodule Cmd.ConversationsTest do
  use Fnord.TestCase, async: false

  setup do
    set_config(quiet: true)
    {:ok, project: mock_project("test_proj")}
  end

  test "listing with no conversations prints no-found message", %{project: project} do
    {output, _stderr} =
      capture_all(fn ->
        Cmd.Conversations.run(%{project: project.name}, [], [])
      end)

    assert output =~ "No conversations found."
  end

  test "prune with no conversations only prints prune info and no JSON", %{project: project} do
    :ok = :meck.new(UI, [:non_strict])
    :meck.expect(UI, :info, fn msg -> IO.puts(:stderr, msg) end)
    :meck.expect(UI, :error, fn msg -> IO.puts(:stderr, msg) end)

    {_stdout, output} =
      capture_all(fn ->
        Cmd.Conversations.run(%{project: project.name, prune: "30"}, [], [])
      end)

    assert output =~ "Pruning conversations older than 30 days"
    assert output =~ "No conversations to prune."
    refute output =~ "["

    :meck.unload(UI)
  end

  test "prune deletes matching old conversations", %{project: project} do
    # Create a conversation file 40 days old
    id = "old_conv"
    conv = Store.Project.Conversation.new(id, project)
    old_ts = DateTime.utc_now() |> DateTime.add(-40 * 24 * 3600, :second) |> DateTime.to_unix()
    File.mkdir_p!(Path.dirname(conv.store_path))
    File.write!(conv.store_path, "#{old_ts}:[]")

    # Stub confirmation to true
    :ok = :meck.new(UI, [:non_strict])
    :meck.expect(UI, :confirm, fn _ -> true end)
    :meck.expect(UI, :info, fn msg -> IO.puts(:stderr, msg) end)
    :meck.expect(UI, :error, fn msg -> IO.puts(:stderr, msg) end)

    {_stdout, output} =
      capture_all(fn ->
        Cmd.Conversations.run(%{project: project.name, prune: "30"}, [], [])
      end)

    assert output =~ "Pruning conversations older than 30 days"
    assert output =~ id
    assert output =~ "Deleted 1 conversation(s)."
    refute output =~ "["
    refute File.exists?(conv.store_path)

    :meck.unload(UI)
  end

  test "prune deletes conversation index entries", %{project: project} do
    # Create a conversation file 40 days old
    id = "indexed_conv"
    conv = Store.Project.Conversation.new(id, project)
    old_ts = DateTime.utc_now() |> DateTime.add(-40 * 24 * 3600, :second) |> DateTime.to_unix()
    File.mkdir_p!(Path.dirname(conv.store_path))
    File.write!(conv.store_path, "#{old_ts}:[]")

    # Write a dummy index entry for the conversation
    index_dir = Store.Project.ConversationIndex.path_for(project, id)
    File.mkdir_p!(index_dir)

    Store.Project.ConversationIndex.write_embeddings(project, conv.id, [%{dummy: "data"}], %{
      "last_indexed_ts" => old_ts
    })

    # Stub confirmation to true
    :ok = :meck.new(UI, [:non_strict])
    :meck.expect(UI, :confirm, fn _ -> true end)
    :meck.expect(UI, :info, fn msg -> IO.puts(:stderr, msg) end)
    :meck.expect(UI, :error, fn msg -> IO.puts(:stderr, msg) end)

    {_stdout, output} =
      capture_all(fn ->
        Cmd.Conversations.run(%{project: project.name, prune: "30"}, [], [])
      end)

    assert output =~ "Pruning conversations older than 30 days"
    refute File.exists?(conv.store_path)
    refute File.exists?(index_dir)

    :meck.unload(UI)
  end

  test "prune cancellation prints only cancellation message", %{project: project} do
    # Create a conversation file 40 days old
    id = "old_cancel"
    conv = Store.Project.Conversation.new(id, project)

    old_ts =
      DateTime.utc_now()
      |> DateTime.add(-40 * 24 * 3600, :second)
      |> DateTime.to_unix()

    File.mkdir_p!(Path.dirname(conv.store_path))
    File.write!(conv.store_path, "#{old_ts}:[]")

    # Stub confirmation to false
    :ok = :meck.new(UI, [:non_strict])
    :meck.expect(UI, :confirm, fn _ -> false end)
    :meck.expect(UI, :info, fn msg -> IO.puts(:stderr, msg) end)
    :meck.expect(UI, :error, fn msg -> IO.puts(:stderr, msg) end)

    {_stdout, output} =
      capture_all(fn ->
        Cmd.Conversations.run(%{project: project.name, prune: "30"}, [], [])
      end)

    assert output =~ "Pruning conversations older than 30 days"
    assert output =~ id
    assert output =~ "Operation cancelled."
    refute output =~ "["
    # Ensure the conversation was not deleted
    assert File.exists?(conv.store_path)

    :meck.unload(UI)
  end

  test "prune by id deletes specific conversation", %{project: project} do
    id = "by_id"
    conv = Store.Project.Conversation.new(id, project)
    File.mkdir_p!(Path.dirname(conv.store_path))
    File.write!(conv.store_path, "#{DateTime.utc_now() |> DateTime.to_unix()}:#{Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "test question"}], "metadata" => %{}, "memory" => []})}")

    # Write a dummy index entry for the conversation
    index_dir = Store.Project.ConversationIndex.path_for(project, id)
    File.mkdir_p!(index_dir)

    Store.Project.ConversationIndex.write_embeddings(project, conv.id, [%{dummy: "data"}], %{
      "last_indexed_ts" => DateTime.utc_now() |> DateTime.to_unix()
    })

    # Stub confirmation to true
    :ok = :meck.new(UI, [:non_strict])
    :meck.expect(UI, :confirm, fn _ -> true end)
    :meck.expect(UI, :info, fn msg -> IO.puts(:stderr, msg) end)
    :meck.expect(UI, :error, fn msg -> IO.puts(:stderr, msg) end)

    {_stdout, output} =
      capture_all(fn ->
        Cmd.Conversations.run(%{project: project.name, prune: id}, [], [])
      end)

    assert output =~ "Deleted conversation #{id}."
    refute File.exists?(conv.store_path)
    refute File.exists?(index_dir)

    :meck.unload(UI)
  end

  test "prune by id non-existent id prints not found", %{project: project} do
    id = "nope"

    :ok = :meck.new(UI, [:non_strict])
    :meck.expect(UI, :confirm, fn _ -> true end)
    :meck.expect(UI, :info, fn msg -> IO.puts(:stderr, msg) end)
    :meck.expect(UI, :error, fn msg -> IO.puts(:stderr, msg) end)

    {_stdout, output} =
      capture_all(fn ->
        Cmd.Conversations.run(%{project: project.name, prune: id}, [], [])
      end)

    assert output =~ "Conversation #{id} not found."

    :meck.unload(UI)
  end

  test "prune by id cancellation leaves conversation intact", %{project: project} do
    id = "cancel_id"
    conv = Store.Project.Conversation.new(id, project)
    File.mkdir_p!(Path.dirname(conv.store_path))
    File.write!(conv.store_path, "#{DateTime.utc_now() |> DateTime.to_unix()}:#{Jason.encode!(%{"messages" => [%{"role" => "user", "content" => "test question"}], "metadata" => %{}, "memory" => []})}")

    # Stub confirmation to false
    :ok = :meck.new(UI, [:non_strict])
    :meck.expect(UI, :confirm, fn _ -> false end)
    :meck.expect(UI, :info, fn msg -> IO.puts(:stderr, msg) end)
    :meck.expect(UI, :error, fn msg -> IO.puts(:stderr, msg) end)

    {_stdout, output} =
      capture_all(fn ->
        Cmd.Conversations.run(%{project: project.name, prune: id}, [], [])
      end)

    assert output =~ id
    assert output =~ "Operation cancelled."
    assert File.exists?(conv.store_path)

    :meck.unload(UI)
  end

  test "invalid prune value emits error and does not list", %{project: project} do
    :ok = :meck.new(UI, [:non_strict])
    :meck.expect(UI, :info, fn msg -> IO.puts(:stderr, msg) end)
    :meck.expect(UI, :error, fn msg -> IO.puts(:stderr, msg) end)

    {_stdout, output} =
      capture_all(fn ->
        Cmd.Conversations.run(%{project: project.name, prune: "-5"}, [], [])
      end)

    assert output =~ "Invalid --prune value: -5"
    refute output =~ "["

    :meck.unload(UI)
  end

  test "semantic search returns formatted results", %{project: project} do
    # Setup stub indexer
    Services.Globals.put_env(:fnord, :indexer, StubIndexer)

    # Create conversations with simple messages
    id1 = "conv1"
    conv1 = Store.Project.Conversation.new(id1, project)
    File.mkdir_p!(Path.dirname(conv1.store_path))

    File.write!(
      conv1.store_path,
      "#{DateTime.utc_now() |> DateTime.to_unix()}:{\"messages\": []}"
    )

    id2 = "conv2"
    conv2 = Store.Project.Conversation.new(id2, project)
    File.mkdir_p!(Path.dirname(conv2.store_path))

    File.write!(
      conv2.store_path,
      "#{DateTime.utc_now() |> DateTime.to_unix()}:{\"messages\": []}"
    )

    # Write embeddings with dummy vectors
    ts = DateTime.utc_now() |> DateTime.to_unix()

    Store.Project.ConversationIndex.write_embeddings(
      project,
      conv1.id,
      [%{embedding: [0.1, 0.2]}],
      %{"last_indexed_ts" => ts}
    )

    Store.Project.ConversationIndex.write_embeddings(project, conv1.id, [1.0, 2.0, 3.0], %{
      "last_indexed_ts" => ts
    })

    Store.Project.ConversationIndex.write_embeddings(project, conv2.id, [3.0, 2.0, 1.0], %{
      "last_indexed_ts" => ts
    })

    # Run semantic search
    {output, _stderr} =
      capture_all(fn ->
        Cmd.Conversations.run(%{project: project.name, query: "alpha", limit: 2}, [], [])
      end)

    lines = String.split(output, "\n", trim: true)
    assert length(lines) == 2

    for line <- lines do
      parts = String.split(line, "\t")
      assert length(parts) == 5
    end
  end
end

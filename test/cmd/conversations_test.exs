defmodule Cmd.ConversationsTest do
  use Fnord.TestCase
  import ExUnit.CaptureIO

  setup do
    set_config(quiet: true)
    {:ok, project: mock_project("test_proj")}
  end

  test "listing with no conversations prints no-found message", %{project: project} do
    output =
      capture_io(fn ->
        Cmd.Conversations.run(%{project: project.name}, [], [])
      end)

    assert output =~ "No conversations found."
  end

  test "prune with no conversations only prints prune info and no JSON", %{project: project} do
    :ok = :meck.new(UI, [:non_strict])
    :meck.expect(UI, :info, fn msg -> IO.puts(:stderr, msg) end)
    :meck.expect(UI, :error, fn msg -> IO.puts(:stderr, msg) end)

    output =
      capture_io(:stderr, fn ->
        Cmd.Conversations.run(%{project: project.name, prune: 30}, [], [])
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

    output =
      capture_io(:stderr, fn ->
        Cmd.Conversations.run(%{project: project.name, prune: 30}, [], [])
      end)

    assert output =~ "Pruning conversations older than 30 days"
    assert output =~ id
    assert output =~ "Deleted 1 conversation(s)."
    refute output =~ "["
    refute File.exists?(conv.store_path)

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

    output =
      capture_io(:stderr, fn ->
        Cmd.Conversations.run(%{project: project.name, prune: 30}, [], [])
      end)

    assert output =~ "Pruning conversations older than 30 days"
    assert output =~ id
    assert output =~ "Operation cancelled."
    refute output =~ "["
    # Ensure the conversation was not deleted
    assert File.exists?(conv.store_path)

    :meck.unload(UI)
  end

  # TODO: Add tests for --prune and default listing behavior.
  test "invalid prune value emits error and does not list", %{project: project} do
    :ok = :meck.new(UI, [:non_strict])
    :meck.expect(UI, :info, fn msg -> IO.puts(:stderr, msg) end)
    :meck.expect(UI, :error, fn msg -> IO.puts(:stderr, msg) end)

    output =
      capture_io(:stderr, fn ->
        Cmd.Conversations.run(%{project: project.name, prune: -5}, [], [])
      end)

    assert output =~ "Invalid --prune value: -5"
    refute output =~ "["

    :meck.unload(UI)
  end
end


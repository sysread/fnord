defmodule Services.Conversation.TaskListMetaTest do
  use Fnord.TestCase, async: false

  alias Services.Conversation

  setup do
    # Initialize project and conversation services
    mock_project("test_project_conv_meta")
    %{conversation: _conv, conversation_pid: pid} = mock_conversation()
    %{pid: pid}
  end

  describe "task list metadata operations" do
    test "set and get metadata for existing task list", %{pid: pid} do
      list_id = 1
      tasks = [%{id: "task1", data: "info"}]

      # Create the list
      assert :ok = Conversation.upsert_task_list(pid, list_id, tasks)

      # Ensure no metadata initially (meta map with nils)
      assert {:ok, %{description: nil, status: nil}} =
               Conversation.get_task_list_meta(pid, list_id)

      # Set description
      assert :ok =
               Conversation.upsert_task_list_meta(pid, list_id, %{
                 description: "My list description"
               })

      # Get description
      assert {:ok, %{description: "My list description"}} =
               Conversation.get_task_list_meta(pid, list_id)
    end

    test "status-only metadata updates preserve the existing description", %{pid: pid} do
      list_id = 2
      tasks = [%{id: "task1", data: "info"}]

      assert :ok = Conversation.upsert_task_list(pid, list_id, tasks)

      assert :ok =
               Conversation.upsert_task_list_meta(pid, list_id, %{
                 description: "Persistent description"
               })

      assert :ok =
               Conversation.upsert_task_list_meta(pid, list_id, %{
                 status: :in_progress
               })

      assert {:ok, %{description: "Persistent description", status: :in_progress}} =
               Conversation.get_task_list_meta(pid, list_id)
    end

    test "meta operations on nonexistent list return error", %{pid: pid} do
      missing = 999
      assert {:error, :not_found} = Conversation.get_task_list_meta(pid, missing)
      assert {:error, :not_found} = Conversation.upsert_task_list_meta(pid, missing, "desc")
    end
  end

  describe "conversation metadata operations" do
    test "updates conversation metadata worktree and preserves existing keys", %{pid: pid} do
      assert :ok =
               Conversation.upsert_conversation_meta(pid, %{
                 worktree: %{path: "/tmp/worktree", branch: "main"}
               })

      assert %{worktree: %{path: "/tmp/worktree", branch: "main"}} =
               Conversation.get_conversation_meta(pid)

      assert :ok = Conversation.upsert_conversation_meta(pid, %{owner: "alice"})

      assert %{worktree: %{path: "/tmp/worktree", branch: "main"}, owner: "alice"} =
               Conversation.get_conversation_meta(pid)
    end

    test "loads legacy conversation data with defaulted metadata, memory, and tasks" do
      conversation = Store.Project.Conversation.new("legacy-conversation")
      File.mkdir_p!(Path.dirname(conversation.store_path))

      payload = %{messages: [%{role: "user", content: "hello from the past"}]}
      contents = Integer.to_string(System.system_time(:second)) <> ":" <> Jason.encode!(payload)
      File.write!(conversation.store_path, contents)

      assert {:ok, pid} = Services.Conversation.start_link(conversation.id)
      assert Conversation.get_conversation_meta(pid) == %{}
      assert Conversation.get_memory(pid) == []
      assert Conversation.get_task_lists(pid) == []
      assert [%{role: "user", content: "hello from the past"}] = Conversation.get_messages(pid)
    end

    test "returns not_found when conversation pid is missing" do
      assert catch_exit(Conversation.get_conversation_meta(:missing_pid))

      assert catch_exit(Conversation.upsert_conversation_meta(:missing_pid, %{worktree: %{}}))
    end
  end
end

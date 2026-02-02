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

      # Ensure no metadata initially
      assert {:ok, nil} = Conversation.get_task_list_meta(pid, list_id)

      # Set description
      assert :ok = Conversation.upsert_task_list_meta(pid, list_id, "My list description")
      # Get description
      assert {:ok, "My list description"} = Conversation.get_task_list_meta(pid, list_id)
    end

    test "meta operations on nonexistent list return error", %{pid: pid} do
      missing = 999
      assert {:error, :not_found} = Conversation.get_task_list_meta(pid, missing)
      assert {:error, :not_found} = Conversation.upsert_task_list_meta(pid, missing, "desc")
    end
  end
end

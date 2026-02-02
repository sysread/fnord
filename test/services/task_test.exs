defmodule Services.TaskTest do
  use Fnord.TestCase, async: false

  setup do
    # Create a mock project
    project = mock_project("test_project_task_service")
    %{conversation: conversation, conversation_pid: pid} = mock_conversation()

    # Return the setup data
    {:ok,
     %{
       project: project,
       conversation: conversation,
       conversation_pid: pid
     }}
  end

  test "start_list/0" do
    assert "tasks-1" = Services.Task.start_list()
    assert "tasks-2" = Services.Task.start_list()
    assert "tasks-3" = Services.Task.start_list()
  end

  test "task management" do
    list_id = Services.Task.start_list()

    assert :ok = Services.Task.add_task(list_id, "Task 1", %{data: "Data 1"})
    assert :ok = Services.Task.add_task(list_id, "Task 2", %{data: "Data 2"})
    assert :ok = Services.Task.add_task(list_id, "Task 3", %{data: "Data 3"})
    assert :ok = Services.Task.push_task(list_id, "Task 0", %{data: "Data 0"})

    tasks = Services.Task.get_list(list_id)
    assert length(tasks) == 4

    assert Services.Task.as_string(list_id) ==
             """
             Task List #{list_id}:
             [ ] Task 0
             [ ] Task 1
             [ ] Task 2
             [ ] Task 3
             """

    assert :ok = Services.Task.complete_task(list_id, "Task 1", "Result 1")
    assert :ok = Services.Task.fail_task(list_id, "Task 2", "Failed due to error")

    assert [
             %{id: "Task 0", outcome: :todo, data: %{data: "Data 0"}, result: nil},
             %{id: "Task 1", outcome: :done, result: "Result 1"},
             %{id: "Task 2", outcome: :failed, result: "Failed due to error"},
             %{id: "Task 3", outcome: :todo, data: %{data: "Data 3"}, result: nil}
           ] = Services.Task.get_list(list_id)

    assert Services.Task.as_string(list_id) ==
             """
             Task List #{list_id}:
             [ ] Task 0
             [✓] Task 1
             [✗] Task 2
             [ ] Task 3
             """
  end

  describe "setting and getting description" do
    test "set_description/2 and get_description/1" do
      list_id = Services.Task.start_list()
      # Set a description and retrieve it
      assert :ok = Services.Task.set_description(list_id, "My description")
      assert {:ok, "My description"} = Services.Task.get_description(list_id)
      # as_string should include the description in the header
      rendered = Services.Task.as_string(list_id)
      assert rendered |> String.contains?("Task List #{list_id}: My description")
    end
  end

  describe "operations on invalid/nonexistent list IDs" do
    test "get, add, complete, and fail on nonexistent list" do
      invalid_id = 999
      # get_list should return {:error, :not_found}
      assert {:error, :not_found} = Services.Task.get_list(invalid_id)

      # add_task should return :ok but not create a list
      assert :ok = Services.Task.add_task(invalid_id, "TaskX", %{foo: "bar"})
      assert {:error, :not_found} = Services.Task.get_list(invalid_id)

      # complete_task should return :ok but not create a list
      assert :ok = Services.Task.complete_task(invalid_id, "TaskX", "Result")
      assert {:error, :not_found} = Services.Task.get_list(invalid_id)

      # fail_task should return :ok but not create a list
      assert :ok = Services.Task.fail_task(invalid_id, "TaskX", "Error")
      assert {:error, :not_found} = Services.Task.get_list(invalid_id)
    end
  end

  describe "completing/failing nonexistent task IDs" do
    test "complete non-existent task leaves list unchanged" do
      list_id = Services.Task.start_list()
      assert :ok = Services.Task.add_task(list_id, "existing", %{data: 1})
      tasks_before = Services.Task.get_list(list_id)
      assert :ok = Services.Task.complete_task(list_id, "nonexistent", "Result")
      assert Services.Task.get_list(list_id) == tasks_before
    end

    test "fail non-existent task leaves list unchanged" do
      list_id = Services.Task.start_list()
      assert :ok = Services.Task.add_task(list_id, "existing", %{data: 2})
      tasks_before = Services.Task.get_list(list_id)
      assert :ok = Services.Task.fail_task(list_id, "nonexistent", "Error")
      assert Services.Task.get_list(list_id) == tasks_before
    end
  end

  describe "adding duplicate task IDs" do
    test "resolving a task id resolves all matching todo duplicates", %{conversation_pid: pid} do
      list_id = Services.Task.start_list()
      task1 = %{id: "dup", data: %{foo: 1}, outcome: "todo", result: nil}
      task2 = %{id: "dup", data: %{bar: 2}, outcome: "todo", result: nil}
      assert :ok = Services.Conversation.upsert_task_list(pid, list_id, [task1, task2])
      GenServer.stop(Services.Task)
      {:ok, _} = Services.Task.start_link(conversation_pid: pid)

      assert [%{id: "dup", outcome: :todo}, %{id: "dup", outcome: :todo}] =
               Services.Task.get_list(list_id)

      assert :ok = Services.Task.complete_task(list_id, "dup", "ok")

      assert [
               %{id: "dup", outcome: :done, result: "ok"},
               %{id: "dup", outcome: :done, result: "ok"}
             ] = Services.Task.get_list(list_id)
    end
  end

  describe "malformed/unexpected task data" do
    test "accepts nil, empty map, and unusual data types" do
      list_id = Services.Task.start_list()
      assert :ok = Services.Task.add_task(list_id, "nil_task", nil)
      assert :ok = Services.Task.add_task(list_id, "empty_map_task", %{})
      weird_data = [:a, :b, :c]
      assert :ok = Services.Task.add_task(list_id, "list_task", weird_data)
      tasks = Services.Task.get_list(list_id)

      assert [
               %{id: "nil_task", outcome: :todo, data: nil, result: nil},
               %{id: "empty_map_task", outcome: :todo, data: %{}, result: nil},
               %{id: "list_task", outcome: :todo, data: ^weird_data, result: nil}
             ] = tasks
    end
  end

  describe "multiple lists isolation" do
    test "operations on multiple lists do not interfere" do
      list1 = Services.Task.start_list()
      list2 = Services.Task.start_list()
      assert :ok = Services.Task.add_task(list1, "task1", %{val: 1})
      assert :ok = Services.Task.add_task(list2, "task2", %{val: 2})
      assert :ok = Services.Task.complete_task(list1, "task1", "ok")
      assert :ok = Services.Task.fail_task(list2, "task2", "error")
      assert [%{id: "task1", outcome: :done, result: "ok"}] = Services.Task.get_list(list1)
      assert [%{id: "task2", outcome: :failed, result: "error"}] = Services.Task.get_list(list2)
    end
  end

  describe "persistence and rehydration across restart" do
    test "persists state and rehydrates after restart", %{
      conversation: conversation,
      conversation_pid: pid
    } do
      list_id = Services.Task.start_list()
      assert :ok = Services.Task.add_task(list_id, "Persistent", %{foo: "bar"})
      assert :ok = Services.Task.complete_task(list_id, "Persistent", "Done")
      # Ensure the conversation has up-to-date tasks before saving
      # Poll until conversation returns the expected tasks
      assert [%{id: "Persistent", outcome: :done, result: "Done", data: _}] =
               Services.Conversation.get_task_list(pid, list_id)

      {:ok, _} = Services.Conversation.save(pid)
      GenServer.stop(Services.Task)
      GenServer.stop(pid)
      {:ok, new_pid} = Services.Conversation.start_link(conversation.id)
      {:ok, _} = Services.Task.start_link(conversation_pid: new_pid)
      tasks = Services.Task.get_list(list_id)
      assert [%{id: "Persistent", outcome: :done, result: "Done"}] = tasks
    end
  end

  describe "peek_task/1" do
    test "returns {:error, :not_found} when list missing" do
      assert {:error, :not_found} = Services.Task.peek_task("nonexistent-list")
    end

    test "returns {:error, :empty} when no todos remain" do
      list_id = Services.Task.start_list()
      :ok = Services.Task.add_task(list_id, "done1", %{})
      :ok = Services.Task.complete_task(list_id, "done1", "ok")
      assert {:error, :empty} = Services.Task.peek_task(list_id)
    end

    test "returns first todo in chronological order" do
      list_id = Services.Task.start_list()
      :ok = Services.Task.add_task(list_id, "a", %{})
      :ok = Services.Task.add_task(list_id, "b", %{})
      :ok = Services.Task.add_task(list_id, "c", %{})
      assert {:ok, %{id: "a", outcome: :todo}} = Services.Task.peek_task(list_id)
    end

    test "skips done and failed tasks to find first todo" do
      list_id = Services.Task.start_list()
      :ok = Services.Task.add_task(list_id, "done", %{})
      :ok = Services.Task.add_task(list_id, "failed", %{})
      :ok = Services.Task.add_task(list_id, "todo", %{})
      :ok = Services.Task.complete_task(list_id, "done", "ok")
      :ok = Services.Task.fail_task(list_id, "failed", "error")
      assert {:ok, %{id: "todo", outcome: :todo}} = Services.Task.peek_task(list_id)
    end
  end

  describe "all_tasks_complete?/1" do
    test "returns {:error, :not_found} on missing list" do
      assert {:error, :not_found} = Services.Task.all_tasks_complete?("nonexistent-list")
    end

    test "returns {:ok, false} when todos remain" do
      list_id = Services.Task.start_list()
      :ok = Services.Task.add_task(list_id, "a", %{})
      :ok = Services.Task.add_task(list_id, "b", %{})
      :ok = Services.Task.complete_task(list_id, "a", "ok")
      assert {:ok, false} = Services.Task.all_tasks_complete?(list_id)
    end

    test "returns {:ok, true} when no todos remain" do
      list_id = Services.Task.start_list()
      :ok = Services.Task.add_task(list_id, "a", %{})
      :ok = Services.Task.add_task(list_id, "b", %{})
      :ok = Services.Task.complete_task(list_id, "a", "ok")
      :ok = Services.Task.fail_task(list_id, "b", "error")
      assert {:ok, true} = Services.Task.all_tasks_complete?(list_id)
    end

    test "returns {:ok, true} for empty list" do
      list_id = Services.Task.start_list()
      assert {:ok, true} = Services.Task.all_tasks_complete?(list_id)
    end
  end

  describe "as_string/2 detailed rendering" do
    test "includes result for done and failed when detail? is true" do
      list_id = Services.Task.start_list()
      :ok = Services.Task.add_task(list_id, "task1", %{})
      :ok = Services.Task.add_task(list_id, "task2", %{})
      :ok = Services.Task.add_task(list_id, "task3", %{})
      :ok = Services.Task.complete_task(list_id, "task1", "success result")
      :ok = Services.Task.fail_task(list_id, "task2", "failure reason")

      detailed = Services.Task.as_string(list_id, true)
      assert detailed =~ "[✓] task1: success result"
      assert detailed =~ "[✗] task2: failure reason"
      assert detailed =~ "[ ] task3"
      refute detailed =~ "task3:"
    end

    test "includes description in header when present" do
      list_id = Services.Task.start_list()
      :ok = Services.Task.set_description(list_id, "My task list")
      :ok = Services.Task.add_task(list_id, "task1", %{})

      output = Services.Task.as_string(list_id)
      assert output =~ "Task List #{list_id}: My task list"
    end

    test "includes colon but no description when description is nil" do
      list_id = Services.Task.start_list()
      :ok = Services.Task.add_task(list_id, "task1", %{})

      output = Services.Task.as_string(list_id)
      assert output =~ "Task List #{list_id}:"
      refute output =~ "Task List #{list_id}: "
    end
  end
end

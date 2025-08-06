defmodule TaskServerTest do
  use Fnord.TestCase, async: false

  setup do
    {:ok, pid} = TaskServer.start_link()
    %{pid: pid}
  end

  test "start_link/0", %{pid: pid} do
    assert Process.alive?(pid)
  end

  test "start_list/0" do
    assert 1 = TaskServer.start_list()
    assert 2 = TaskServer.start_list()
    assert 3 = TaskServer.start_list()
  end

  test "task management" do
    list_id = TaskServer.start_list()

    assert :ok = TaskServer.add_task(list_id, "Task 1", %{data: "Data 1"})
    assert :ok = TaskServer.add_task(list_id, "Task 2", %{data: "Data 2"})
    assert :ok = TaskServer.add_task(list_id, "Task 3", %{data: "Data 3"})

    tasks = TaskServer.get_list(list_id)
    assert length(tasks) == 3

    assert TaskServer.as_string(list_id) ==
             """
             - [ ] Task 1
             - [ ] Task 2
             - [ ] Task 3
             """

    assert :ok = TaskServer.complete_task(list_id, "Task 1", "Result 1")
    assert :ok = TaskServer.fail_task(list_id, "Task 2", "Failed due to error")

    assert [
             %{id: "Task 1", outcome: :done, result: "Result 1"},
             %{id: "Task 2", outcome: :failed, result: "Failed due to error"},
             %{id: "Task 3", outcome: :todo, data: %{data: "Data 3"}, result: nil}
           ] = TaskServer.get_list(list_id)

    assert TaskServer.as_string(list_id) ==
             """
             - [✓] Task 1
             - [✗] Task 2
             - [ ] Task 3
             """
  end

  describe "operations on invalid/nonexistent list IDs" do
    test "get, add, complete, and fail on nonexistent list" do
      invalid_id = 999
      # get_list should return {:error, :not_found}
      assert {:error, :not_found} = TaskServer.get_list(invalid_id)

      # add_task should return :ok but not create a list
      assert :ok = TaskServer.add_task(invalid_id, "TaskX", %{foo: "bar"})
      assert {:error, :not_found} = TaskServer.get_list(invalid_id)

      # complete_task should return :ok but not create a list
      assert :ok = TaskServer.complete_task(invalid_id, "TaskX", "Result")
      assert {:error, :not_found} = TaskServer.get_list(invalid_id)

      # fail_task should return :ok but not create a list
      assert :ok = TaskServer.fail_task(invalid_id, "TaskX", "Error")
      assert {:error, :not_found} = TaskServer.get_list(invalid_id)
    end
  end

  describe "completing/failing nonexistent task IDs" do
    test "complete non-existent task leaves list unchanged" do
      list_id = TaskServer.start_list()
      assert :ok = TaskServer.add_task(list_id, "existing", %{data: 1})
      tasks_before = TaskServer.get_list(list_id)
      assert :ok = TaskServer.complete_task(list_id, "nonexistent", "Result")
      assert TaskServer.get_list(list_id) == tasks_before
    end

    test "fail non-existent task leaves list unchanged" do
      list_id = TaskServer.start_list()
      assert :ok = TaskServer.add_task(list_id, "existing", %{data: 2})
      tasks_before = TaskServer.get_list(list_id)
      assert :ok = TaskServer.fail_task(list_id, "nonexistent", "Error")
      assert TaskServer.get_list(list_id) == tasks_before
    end
  end

  describe "adding duplicate task IDs" do
    test "allows duplicate task IDs and preserves order" do
      list_id = TaskServer.start_list()
      data1 = %{foo: 1}
      data2 = %{bar: 2}
      assert :ok = TaskServer.add_task(list_id, "dup", data1)
      assert :ok = TaskServer.add_task(list_id, "dup", data2)
      tasks = TaskServer.get_list(list_id)

      assert [
               %{id: "dup", outcome: :todo, data: ^data1, result: nil},
               %{id: "dup", outcome: :todo, data: ^data2, result: nil}
             ] = tasks
    end
  end

  describe "malformed/unexpected task data" do
    test "accepts nil, empty map, and unusual data types" do
      list_id = TaskServer.start_list()
      assert :ok = TaskServer.add_task(list_id, "nil_task", nil)
      assert :ok = TaskServer.add_task(list_id, "empty_map_task", %{})
      weird_data = [:a, :b, :c]
      assert :ok = TaskServer.add_task(list_id, "list_task", weird_data)
      tasks = TaskServer.get_list(list_id)

      assert [
               %{id: "nil_task", outcome: :todo, data: nil, result: nil},
               %{id: "empty_map_task", outcome: :todo, data: %{}, result: nil},
               %{id: "list_task", outcome: :todo, data: ^weird_data, result: nil}
             ] = tasks
    end
  end

  describe "multiple lists isolation" do
    test "operations on multiple lists do not interfere" do
      list1 = TaskServer.start_list()
      list2 = TaskServer.start_list()
      assert :ok = TaskServer.add_task(list1, "task1", %{val: 1})
      assert :ok = TaskServer.add_task(list2, "task2", %{val: 2})
      assert :ok = TaskServer.complete_task(list1, "task1", "ok")
      assert :ok = TaskServer.fail_task(list2, "task2", "error")
      assert [%{id: "task1", outcome: :done, result: "ok"}] = TaskServer.get_list(list1)
      assert [%{id: "task2", outcome: :failed, result: "error"}] = TaskServer.get_list(list2)
    end
  end

  describe "stack operations" do
    test "push_task adds task to top of stack" do
      list_id = TaskServer.start_list()
      assert :ok = TaskServer.add_task(list_id, "bottom", %{order: 1})
      assert :ok = TaskServer.push_task(list_id, "top", %{order: 2})

      assert [
               %{id: "top", outcome: :todo},
               %{id: "bottom", outcome: :todo}
             ] = TaskServer.get_list(list_id)
    end

    test "peek_task returns current task without removing it" do
      list_id = TaskServer.start_list()
      assert :ok = TaskServer.push_task(list_id, "first", %{data: 1})
      assert :ok = TaskServer.push_task(list_id, "second", %{data: 2})

      # Peek should return the most recently pushed task
      assert {:ok, %{id: "second", outcome: :todo, data: %{data: 2}}} =
               TaskServer.peek_task(list_id)

      # Task should still be there after peek
      assert {:ok, %{id: "second"}} = TaskServer.peek_task(list_id)
    end

    test "peek_task on empty list returns error" do
      list_id = TaskServer.start_list()
      assert {:error, :empty} = TaskServer.peek_task(list_id)
    end

    test "peek_task on nonexistent list returns error" do
      assert {:error, :not_found} = TaskServer.peek_task(999)
    end

    test "peek_task shows only :todos" do
      list_id = TaskServer.start_list()
      assert :ok = TaskServer.push_task(list_id, "task1", %{data: 1})
      assert :ok = TaskServer.push_task(list_id, "task2", %{data: 2})
      assert :ok = TaskServer.complete_task(list_id, "task2", "done")

      assert [
               %{id: "task2", outcome: :done, result: "done"},
               %{id: "task1", outcome: :todo, data: %{data: 1}, result: nil}
             ] = TaskServer.get_list(list_id)

      # Peek should return the first todo task
      assert {:ok, %{id: "task1", outcome: :todo}} = TaskServer.peek_task(list_id)
    end
  end
end

defmodule Services.TaskTest do
  use Fnord.TestCase, async: false

  test "start_list/0" do
    assert 1 = Services.Task.start_list()
    assert 2 = Services.Task.start_list()
    assert 3 = Services.Task.start_list()
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
    test "allows duplicate task IDs and preserves order" do
      list_id = Services.Task.start_list()
      data1 = %{foo: 1}
      data2 = %{bar: 2}
      assert :ok = Services.Task.add_task(list_id, "dup", data1)
      assert :ok = Services.Task.add_task(list_id, "dup", data2)
      tasks = Services.Task.get_list(list_id)

      assert [%{id: "dup", outcome: :todo, data: ^data1, result: nil}] = tasks
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
end

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
end

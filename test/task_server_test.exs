defmodule TaskServerTest do
  use Fnord.TestCase, async: false

  setup do
    {:ok, pid} = TaskServer.start_link()
    %{pid: pid}
  end

  test "start_link/0 starts the GenServer and it is alive", %{pid: pid} do
    assert Process.alive?(pid)
  end

  test "start_list/0 returns unique, incrementing positive integer IDs" do
    first_id = TaskServer.start_list()
    second_id = TaskServer.start_list()
    assert is_integer(first_id) and first_id > 0
    assert second_id == first_id + 1
  end

  test "get_list/1 returns [] for unknown IDs", %{pid: _pid} do
    assert TaskServer.get_list(9999) == []
  end

  test "add_task/2 adds tasks to a valid list and retrieves them in order with :todo outcome" do
    list_id = TaskServer.start_list()
    TaskServer.add_task(list_id, "task one")
    TaskServer.add_task(list_id, "task two")
    assert TaskServer.get_list(list_id) == ["task one", "task two"]
  end


  test "complete_task/3 updates outcome for correct task only" do
    list_id = TaskServer.start_list()
    TaskServer.add_task(list_id, "task one")
    TaskServer.add_task(list_id, "task two")
    assert TaskServer.get_list(list_id) == ["task one", "task two"]
    TaskServer.complete_task(list_id, 0, :done)
    assert TaskServer.get_list(list_id) == ["task two"]
  end

  test "add_task/2 and complete_task/3 do nothing for missing IDs" do
    assert TaskServer.get_list(9999) == []
    TaskServer.add_task(9999, "orphan")
    TaskServer.complete_task(9999, 0, :done)
    assert TaskServer.get_list(9999) == []
  end

  test "get_list/1 always returns current tasks in proper order" do
    list_id = TaskServer.start_list()
    assert TaskServer.get_list(list_id) == []

    TaskServer.add_task(list_id, "first")
    assert TaskServer.get_list(list_id) == ["first"]

    TaskServer.add_task(list_id, "second")
    assert TaskServer.get_list(list_id) == ["first", "second"]

    TaskServer.complete_task(list_id, 0, :done)
    assert TaskServer.get_list(list_id) == ["second"]
  end
end

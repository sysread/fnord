defmodule TaskServerTest do
  use ExUnit.Case, async: true
  alias TaskServer

  setup do
    {:ok, pid} = TaskServer.start_link()
    %{pid: pid}
  end

  test "start_link/0 starts the GenServer and it is alive", %{pid: pid} do
    assert Process.alive?(pid)
  end

  test "start_list/0 returns unique, incrementing positive integer IDs", %{pid: _pid} do
    first_id = TaskServer.start_list()
    second_id = TaskServer.start_list()
    assert is_integer(first_id) and first_id > 0
    assert second_id == first_id + 1
  end

  test "get_list/1 returns [] for unknown IDs", %{pid: _pid} do
    assert TaskServer.get_list(9999) == []
  end

  test "add_task/2 adds tasks to a valid list and retrieves them in order with :todo outcome", %{
    pid: _pid
  } do
    list_id = TaskServer.start_list()
    TaskServer.add_task(list_id, "task one")
    TaskServer.add_task(list_id, "task two")

    assert TaskServer.get_list(list_id) == [
             %{name: "task one", outcome: :todo},
             %{name: "task two", outcome: :todo}
           ]
  end

  test "complete_task/3 updates outcome for correct task only", %{pid: _pid} do
    list_id = TaskServer.start_list()
    TaskServer.add_task(list_id, "task one")
    TaskServer.add_task(list_id, "task two")
    TaskServer.complete_task(list_id, 0, :done)

    assert TaskServer.get_list(list_id) == [
             %{name: "task one", outcome: :done},
             %{name: "task two", outcome: :todo}
           ]
  end

  test "add_task/2 and complete_task/3 do nothing for missing IDs", %{pid: _pid} do
    assert TaskServer.get_list(9999) == []
    TaskServer.add_task(9999, "orphan")
    TaskServer.complete_task(9999, 0, :done)
    assert TaskServer.get_list(9999) == []
  end

  test "get_list/1 always returns current tasks as maps in proper order", %{pid: _pid} do
    list_id = TaskServer.start_list()
    assert TaskServer.get_list(list_id) == []
    TaskServer.add_task(list_id, "first")
    assert TaskServer.get_list(list_id) == [%{name: "first", outcome: :todo}]
    TaskServer.add_task(list_id, "second")

    assert TaskServer.get_list(list_id) == [
             %{name: "first", outcome: :todo},
             %{name: "second", outcome: :todo}
           ]

    TaskServer.complete_task(list_id, 0, :done)

    assert TaskServer.get_list(list_id) == [
             %{name: "first", outcome: :done},
             %{name: "second", outcome: :todo}
           ]
  end
end

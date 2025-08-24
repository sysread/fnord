defmodule Services.NamePoolTest do
  use Fnord.TestCase, async: true

  alias Services.NamePool

  setup do
    case start_supervised({Services.NamePool, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
    NamePool.reset()
    :ok
  end

  test "get_name_by_pid/1 returns name for checking process" do
    {:ok, name} = NamePool.checkout_name()
    assert {:ok, ^name} = NamePool.get_name_by_pid(self())
  end

  test "get_name_by_pid/1 returns error for unknown pid" do
    assert {:error, :not_found} = NamePool.get_name_by_pid(self())
  end

  test "mapping removed on checkin_name" do
    {:ok, name} = NamePool.checkout_name()
    assert {:ok, ^name} = NamePool.get_name_by_pid(self())

    NamePool.checkin_name(name)
    assert {:error, :not_found} = NamePool.get_name_by_pid(self())
  end

  test "distinct pids get distinct names" do
    parent = self()

    pid1 =
      spawn(fn ->
        {:ok, name1} = NamePool.checkout_name()
        send(parent, {:name_pid, name1, self()})
      end)

    pid2 =
      spawn(fn ->
        {:ok, name2} = NamePool.checkout_name()
        send(parent, {:name_pid, name2, self()})
      end)

    assert_receive {:name_pid, name1, ^pid1}, 500
    assert_receive {:name_pid, name2, ^pid2}, 500

    assert name1 != name2
    assert {:ok, ^name1} = NamePool.get_name_by_pid(pid1)
    assert {:ok, ^name2} = NamePool.get_name_by_pid(pid2)
  end
end

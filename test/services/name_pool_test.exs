defmodule Services.NamePoolTest do
  use Fnord.TestCase, async: false

  alias Services.NamePool

  test "get_name_by_pid/1 returns name for checking process" do
    NamePool.reset()
    {:ok, name} = NamePool.checkout_name()
    assert {:ok, ^name} = NamePool.get_name_by_pid(self())
  end

  test "get_name_by_pid/1 returns error for unknown pid" do
    NamePool.reset()
    assert {:error, :not_found} = NamePool.get_name_by_pid(self())
  end

  test "mapping removed on checkin_name" do
    NamePool.reset()
    {:ok, name} = NamePool.checkout_name()
    assert {:ok, ^name} = NamePool.get_name_by_pid(self())

    NamePool.checkin_name(name)
    assert {:error, :not_found} = NamePool.get_name_by_pid(self())
  end

  test "distinct pids get distinct names" do
    NamePool.reset()

    names =
      1..4
      |> Util.async_stream(fn _ ->
        assert {:ok, name} = NamePool.checkout_name()
        assert {:ok, ^name} = NamePool.get_name_by_pid(self())
        name
      end)
      |> Enum.to_list()
      |> Enum.uniq()

    assert length(names) == 4
  end
end

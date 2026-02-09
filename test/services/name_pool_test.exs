defmodule Services.NamePoolTest do
  use Fnord.TestCase, async: false

  alias Services.NamePool

  setup do
    # Force the nomenclater to fake mode for deterministic tests
    prev = Services.Globals.get_env(:fnord, :nomenclater, nil)
    Services.Globals.put_env(:fnord, :nomenclater, :fake)

    on_exit(fn ->
      if is_nil(prev) do
        Services.Globals.delete_env(:fnord, :nomenclater)
      else
        Services.Globals.put_env(:fnord, :nomenclater, prev)
      end
    end)

    :ok
  end

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

  test "checkout_name/0 returns error on timeout" do
    NamePool.reset()

    # Define a dummy GenServer that never replies to handle_call(:checkout_name)
    defmodule NoReplyServer do
      use GenServer

      def init(:ok), do: {:ok, %{}}

      def handle_call(:checkout_name, _from, state) do
        # Do not reply, causing the call to timeout
        {:noreply, state}
      end
    end

    # Start the dummy server
    {:ok, pid} = GenServer.start_link(NoReplyServer, :ok)

    # Ensure the dummy server is stopped when the test exits
    on_exit(fn ->
      if Process.alive?(pid) do
        GenServer.stop(pid)
      end
    end)

    # Call checkout_name with a short timeout and assert timeout error
    assert {:error, :timeout} = NamePool.checkout_name(pid, 1)
  end

  test "checkin_name/1 is a no-op for default name" do
    NamePool.reset()
    assert :ok = NamePool.checkin_name(NamePool.default_name())
  end

  test "checkin_name/1 warns but preserves state when name not checked out" do
    NamePool.reset()
    {:ok, name} = NamePool.checkout_name()
    NamePool.checkin_name("not checked out")
    assert {:ok, ^name} = NamePool.get_name_by_pid(self())
  end

  test "associate_name/1 is a no-op for nil" do
    NamePool.reset()
    assert :ok = NamePool.associate_name(nil)
  end

  test "associate_name/1 remaps name ownership from previous pid" do
    NamePool.reset()
    {:ok, name} = NamePool.checkout_name()
    old_pid = self()

    spawn(fn ->
      NamePool.associate_name(name)
      send(old_pid, {:spawned, self()})
    end)

    assert_receive {:spawned, new_pid}
    assert {:error, :not_found} = NamePool.get_name_by_pid(old_pid)
    assert {:ok, ^name} = NamePool.get_name_by_pid(new_pid)
  end

  test "pool_stats reflects checked-out and available counts" do
    NamePool.reset()
    {:ok, _name1} = NamePool.checkout_name()
    {:ok, _name2} = NamePool.checkout_name()
    stats = NamePool.pool_stats()
    assert stats.checked_out_count == 2
    assert stats.all_used_count >= 2
  end
end

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
end

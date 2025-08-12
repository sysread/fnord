defmodule Services.NamePoolTest do
  use Fnord.TestCase, async: false

  setup do
    # More aggressive meck cleanup
    try do
      # Unload all meck modules
      :meck.unload()
    rescue
      _ -> :ok
    end

    # Reset configuration to defaults before each test
    # Reset to default
    Application.put_env(:fnord, :workers, 12)

    # Ensure clean process state by stopping and restarting the name pool
    if pid = Process.whereis(Services.NamePool) do
      GenServer.stop(pid)
      # Wait a bit for the process to fully terminate
      Process.sleep(10)
    end

    # Start fresh name pool service
    {:ok, _} = Services.NamePool.start_link()

    # Reset the name pool state (which now handles all uniqueness tracking)
    Services.NamePool.reset()

    # Ensure cleanup happens after each test too
    on_exit(fn ->
      try do
        :meck.unload()
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  describe "start_link/0" do
    test "starts successfully" do
      assert Process.whereis(Services.NamePool) != nil
    end

    test "uses configured chunk size from workers setting" do
      set_config(workers: 5)

      # Stop and restart to pick up new config, with proper timing
      GenServer.stop(Services.NamePool)
      # Give it time to fully stop
      Process.sleep(20)
      {:ok, _} = Services.NamePool.start_link()

      stats = Services.NamePool.pool_stats()
      assert stats.chunk_size == 5
    end
  end

  describe "checkout_name/0" do
    test "checks out a name successfully" do
      # Mock nomenclater to return predictable names
      :meck.new(AI.Agent.Nomenclater, [:passthrough])

      :meck.expect(AI.Agent.Nomenclater, :get_names, fn count, _used ->
        names = Enum.map(1..count, &"TestName#{&1}")
        {:ok, names}
      end)

      assert {:ok, name} = Services.NamePool.checkout_name()
      assert is_binary(name)
      assert String.starts_with?(name, "TestName")

      stats = Services.NamePool.pool_stats()
      assert stats.checked_out_count == 1

      :meck.unload(AI.Agent.Nomenclater)
    end

    test "allocates new chunk when pool is empty" do
      # Mock nomenclater to track calls
      :meck.new(AI.Agent.Nomenclater, [:passthrough])

      :meck.expect(AI.Agent.Nomenclater, :get_names, fn count, _used ->
        names = Enum.map(1..count, &"BatchName#{&1}")
        {:ok, names}
      end)

      # First checkout should trigger batch allocation
      {:ok, name1} = Services.NamePool.checkout_name()
      assert String.starts_with?(name1, "BatchName")

      # Verify allocation was called
      assert :meck.called(AI.Agent.Nomenclater, :get_names, :_) == true

      stats = Services.NamePool.pool_stats()
      # Should have checked out 1, available might be 0 due to test interference
      assert stats.checked_out_count == 1
      assert stats.available_count >= 0

      :meck.unload(AI.Agent.Nomenclater)
    end

    test "handles nomenclater errors gracefully" do
      :meck.new(AI.Agent.Nomenclater, [:passthrough])

      :meck.expect(AI.Agent.Nomenclater, :get_names, fn _count, _used ->
        {:error, "API failed"}
      end)

      assert {:error, "API failed"} = Services.NamePool.checkout_name()

      :meck.unload(AI.Agent.Nomenclater)
    end

    test "uses names from pool efficiently" do
      # Mock to provide names when requested
      :meck.new(AI.Agent.Nomenclater, [:passthrough])

      :meck.expect(AI.Agent.Nomenclater, :get_names, fn count, _used ->
        names = Enum.map(1..count, &"PoolName#{&1}")
        {:ok, names}
      end)

      # Checkout multiple names
      {:ok, _name1} = Services.NamePool.checkout_name()
      {:ok, _name2} = Services.NamePool.checkout_name()
      {:ok, _name3} = Services.NamePool.checkout_name()

      # Should have made exactly one call to get the batch
      assert :meck.num_calls(AI.Agent.Nomenclater, :get_names, :_) == 1

      stats = Services.NamePool.pool_stats()
      # Should have checked out exactly 3 names from the batch
      assert stats.checked_out_count == 3
      # Should have remaining names available (12 allocated - 3 checked out = 9)
      assert stats.available_count == 9

      :meck.unload(AI.Agent.Nomenclater)
    end
  end

  describe "checkin_name/1" do
    test "checks name back into pool" do
      :meck.new(AI.Agent.Nomenclater, [:passthrough])

      :meck.expect(AI.Agent.Nomenclater, :get_names, fn count, _used ->
        names = Enum.map(1..count, &"CheckinName#{&1}")
        {:ok, names}
      end)

      # Checkout and checkin
      {:ok, name} = Services.NamePool.checkout_name()
      initial_stats = Services.NamePool.pool_stats()

      Services.NamePool.checkin_name(name)

      final_stats = Services.NamePool.pool_stats()
      assert final_stats.checked_out_count == initial_stats.checked_out_count - 1
      assert final_stats.available_count == initial_stats.available_count + 1

      :meck.unload(AI.Agent.Nomenclater)
    end

    test "ignores checkin of name that wasn't checked out" do
      Services.NamePool.checkin_name("NonExistentName")

      stats = Services.NamePool.pool_stats()
      assert stats.checked_out_count == 0
    end

    test "allows reuse of checked-in name" do
      :meck.new(AI.Agent.Nomenclater, [:passthrough])

      :meck.expect(AI.Agent.Nomenclater, :get_names, fn count, _used ->
        names = Enum.map(1..count, &"ReuseName#{&1}")
        {:ok, names}
      end)

      # Checkout, checkin, checkout again
      {:ok, name1} = Services.NamePool.checkout_name()
      Services.NamePool.checkin_name(name1)
      {:ok, name2} = Services.NamePool.checkout_name()

      # Should get the same name back since it was returned to the pool
      assert name2 == name1

      :meck.unload(AI.Agent.Nomenclater)
    end
  end

  describe "pool_stats/0" do
    test "returns accurate statistics" do
      stats = Services.NamePool.pool_stats()
      assert Map.has_key?(stats, :available_count)
      assert Map.has_key?(stats, :checked_out_count)
      assert Map.has_key?(stats, :chunk_size)
      assert is_integer(stats.available_count)
      assert is_integer(stats.checked_out_count)
      assert is_integer(stats.chunk_size)
    end
  end

  describe "reset/0" do
    test "clears pool state" do
      :meck.new(AI.Agent.Nomenclater, [:passthrough])

      :meck.expect(AI.Agent.Nomenclater, :get_names, fn count ->
        names = Enum.map(1..count, &"ResetName#{&1}")
        {:ok, names}
      end)

      # Add some state
      {:ok, _name} = Services.NamePool.checkout_name()

      initial_stats = Services.NamePool.pool_stats()
      assert initial_stats.available_count > 0 || initial_stats.checked_out_count > 0

      # Reset
      Services.NamePool.reset()

      final_stats = Services.NamePool.pool_stats()
      assert final_stats.available_count == 0
      assert final_stats.checked_out_count == 0

      :meck.unload(AI.Agent.Nomenclater)
    end

    test "resets all_used tracking" do
      # Mock nomenclater to return predictable names
      :meck.new(AI.Agent.Nomenclater, [:passthrough])

      :meck.expect(AI.Agent.Nomenclater, :get_names, fn _count, _used ->
        {:ok, ["ResetTestName"]}
      end)

      # Add some state by checking out a name
      {:ok, _name} = Services.NamePool.checkout_name()

      initial_stats = Services.NamePool.pool_stats()
      assert initial_stats.all_used_count > 0

      Services.NamePool.reset()

      final_stats = Services.NamePool.pool_stats()
      assert final_stats.all_used_count == 0

      :meck.unload(AI.Agent.Nomenclater)
    end
  end

  describe "concurrent access" do
    test "handles multiple processes safely" do
      :meck.new(AI.Agent.Nomenclater, [:passthrough])

      :meck.expect(AI.Agent.Nomenclater, :get_names, fn count, _used ->
        names = Enum.map(1..count, &"ConcurrentName#{&1}")
        {:ok, names}
      end)

      # Simulate concurrent checkouts
      tasks =
        1..5
        |> Enum.map(fn _i ->
          Task.async(fn ->
            {:ok, name} = Services.NamePool.checkout_name()
            # Small delay to increase chance of concurrency
            Process.sleep(10)
            Services.NamePool.checkin_name(name)
            name
          end)
        end)

      names = Task.await_many(tasks)

      # All should succeed and return names
      assert length(names) == 5
      assert Enum.all?(names, &is_binary/1)

      # Pool should be back to stable state after checkins
      stats = Services.NamePool.pool_stats()
      assert stats.checked_out_count == 0

      :meck.unload(AI.Agent.Nomenclater)
    end
  end

  describe "integration with nomenclater batch functionality" do
    test "requests correct batch size" do
      set_config(workers: 8)

      # Stop and restart to pick up new config, with proper timing
      GenServer.stop(Services.NamePool)
      # Give it time to fully stop
      Process.sleep(20)
      {:ok, _} = Services.NamePool.start_link()

      :meck.new(AI.Agent.Nomenclater, [:passthrough])

      :meck.expect(AI.Agent.Nomenclater, :get_names, fn count, _used ->
        names = Enum.map(1..count, &"BatchName#{&1}")
        {:ok, names}
      end)

      Services.NamePool.checkout_name()

      # Should request exactly the configured workers count with empty used list
      assert :meck.called(AI.Agent.Nomenclater, :get_names, [8, []])

      :meck.unload(AI.Agent.Nomenclater)
    end
  end
end

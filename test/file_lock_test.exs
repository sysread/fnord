defmodule FileLockTest do
  use Fnord.TestCase

  @doc false
  defp lock_path(tmp_dir \\ nil) do
    {:ok, dir} =
      if tmp_dir do
        {:ok, tmp_dir}
      else
        Fnord.TestCase.tmpdir()
      end

    Path.join(dir, "lock_target.txt")
  end

  test "with_lock returns {:ok, result} and releases the lock" do
    path = lock_path()

    assert {:ok, :done} = FileLock.with_lock(path, fn -> :done end)
    # lock dir should no longer exist
    refute File.exists?(path <> ".lock")
  end

  test "with_lock returns {:callback_error, _} when callback raises and still releases the lock" do
    path = lock_path()

    assert {:callback_error, %RuntimeError{message: "boom"}} =
             FileLock.with_lock(path, fn -> raise "boom" end)

    refute File.exists?(path <> ".lock")
  end

  test "release_lock is idempotent and safe when no lock exists" do
    path = lock_path()

    # releasing when no lock dir exists should be ok
    assert :ok = FileLock.release_lock(path)

    # acquire then release twice
    assert :ok = FileLock.acquire_lock(path)
    assert :ok = FileLock.release_lock(path)
    assert :ok = FileLock.release_lock(path)
  end

  test "mutual exclusion: callbacks do not overlap under contention" do
    path = lock_path()

    {:ok, meter} = Agent.start_link(fn -> %{current: 0, max: 0} end)

    critical = fn ->
      Agent.update(meter, fn %{current: c, max: m} -> %{current: c + 1, max: max(m, c + 1)} end)
      # small delay to widen the contention window without slowing suite
      Process.sleep(25)
      Agent.update(meter, fn %{current: c, max: m} -> %{current: c - 1, max: m} end)
      :ok
    end

    task_fun = fn parent ->
      send(parent, {:ready, self()})

      receive do
        :go -> :ok
      after
        1_000 -> flunk("barrier not released")
      end

      assert {:ok, :ok} = FileLock.with_lock(path, critical)
    end

    parent = self()
    t1 = Task.async(fn -> task_fun.(parent) end)
    t2 = Task.async(fn -> task_fun.(parent) end)

    # Wait for both tasks to be ready, then release barrier
    pids =
      for _ <- 1..2 do
        receive do
          {:ready, pid} -> pid
        after
          1_000 -> flunk("task did not signal ready")
        end
      end

    Enum.each(pids, fn pid -> send(pid, :go) end)

    assert {:ok, :ok} == Task.await(t1, 5_000)
    assert {:ok, :ok} == Task.await(t2, 5_000)

    %{max: max} = Agent.get(meter, & &1)
    assert max <= 1
  end
end

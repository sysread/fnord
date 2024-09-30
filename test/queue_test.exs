defmodule QueueTest do
  use ExUnit.Case

  def setup do
    {:ok}
  end

  test "workflow", _ do
    assert {:ok, pid} = Queue.start_link(2, &(&1 * &1))
    assert Process.alive?(pid)

    # Test mapping a range of numbers, verify that the results are in the
    # correct order.
    results = Queue.map(1..10, pid)
    assert results == [1, 4, 9, 16, 25, 36, 49, 64, 81, 100]

    # Test shutting down the queue and waiting for it to finish.
    tasks = Enum.map(1..10, &Queue.queue(pid, &1))
    assert Queue.shutdown(pid) == :ok
    assert Queue.join(pid) == :ok
    assert Enum.map(tasks, &Task.await(&1)) == [1, 4, 9, 16, 25, 36, 49, 64, 81, 100]
  end
end

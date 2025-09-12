defmodule TimedTest do
  use Fnord.TestCase
  import ExUnit.CaptureLog

  setup do
    Logger.configure(level: :info)
    :ok
  end

  test "timed returns function result and logs elapsed time" do
    log =
      capture_log(fn ->
        result = Timed.timed("task_name", fn -> :ok end)
        assert result == :ok
      end)

    assert log =~ "task_name"
    assert log =~ "Took"
    assert log =~ "seconds"
  end

  test "timed zero-duration function" do
    log =
      capture_log(fn ->
        result = Timed.timed("fast_task", fn -> 123 end)
        assert result == 123
      end)

    assert log =~ "fast_task"
    assert log =~ "Took"
    assert log =~ "seconds"
  end
end

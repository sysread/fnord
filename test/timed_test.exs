defmodule TimedTest do
  use Fnord.TestCase, async: false
  import ExUnit.CaptureLog

  setup do
    # CRITICAL: register the restore on_exit BEFORE changing the level, so the
    # restore fires even if the test crashes between configure and the next
    # statement. Without on_exit cleanup at all, this setup permanently
    # changes the global Logger level for the rest of the suite.
    orig = Logger.level()
    on_exit(fn -> Logger.configure(level: orig) end)
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

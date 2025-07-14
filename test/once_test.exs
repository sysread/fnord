defmodule OnceTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  setup do
    start_supervised(Once)
    :ok
  end

  test "mark returns true for a new key" do
    assert Once.mark("new_key") == true
  end

  test "mark returns false for an existing key" do
    assert Once.mark("existing_key") == true
    assert Once.mark("existing_key") == false
  end

  test "warn logs the message only once" do
    msg = "hello"

    log =
      capture_log(fn ->
        assert Once.warn(msg) == :ok
      end)

    assert log =~ msg

    log =
      capture_log(fn ->
        assert Once.warn(msg) == :ok
      end)

    assert log == ""
  end

  test "warn logs different messages separately" do
    first = "first"
    second = "second"

    log =
      capture_log(fn ->
        assert Once.warn(first) == :ok
      end)

    assert log =~ first

    log =
      capture_log(fn ->
        assert Once.warn(second) == :ok
      end)

    assert log =~ second
  end
end

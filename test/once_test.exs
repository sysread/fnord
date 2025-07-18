defmodule OnceTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  setup do
    start_supervised(Once)
    :ok
  end

  test "set returns true for a new key" do
    assert Once.set("new_key") == true
  end

  test "set returns false for an existing key" do
    assert Once.set("existing_key") == true
    assert Once.set("existing_key") == false
  end

  test "set returns value for a new key with value" do
    assert Once.set("new_key_with_value", "value") == true
    assert Once.get("new_key_with_value") == {:ok, "value"}
  end

  test "get returns :not_seen for a key that has not been set" do
    assert Once.get("not_seen_key") == {:error, :not_seen}
  end

  test "get returns the value for a key that has been set" do
    assert Once.set("seen_key", "value") == true
    assert Once.get("seen_key") == {:ok, "value"}
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

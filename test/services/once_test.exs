defmodule Services.OnceTest do
  use Fnord.TestCase, async: false

  import ExUnit.CaptureLog

  test "set returns true for a new key" do
    assert Services.Once.set("new_key") == true
  end

  test "set returns false for an existing key" do
    assert Services.Once.set("existing_key") == true
    assert Services.Once.set("existing_key") == false
  end

  test "set returns value for a new key with value" do
    assert Services.Once.set("new_key_with_value", "value") == true
    assert Services.Once.get("new_key_with_value") == {:ok, "value"}
  end

  test "get returns :not_seen for a key that has not been set" do
    assert Services.Once.get("not_seen_key") == {:error, :not_seen}
  end

  test "get returns the value for a key that has been set" do
    assert Services.Once.set("seen_key", "value") == true
    assert Services.Once.get("seen_key") == {:ok, "value"}
  end

  test "warn logs the message only once" do
    set_log_level(:warning)
    msg = "hello"

    log =
      capture_log(fn ->
        assert Services.Once.warn(msg) == :ok
      end)

    assert log =~ msg

    log =
      capture_log(fn ->
        assert Services.Once.warn(msg) == :ok
      end)

    assert log == ""
  end

  test "warn logs different messages separately" do
    set_log_level(:warning)
    first = "first"
    second = "second"

    log =
      capture_log(fn ->
        assert Services.Once.warn(first) == :ok
      end)

    assert log =~ first

    log =
      capture_log(fn ->
        assert Services.Once.warn(second) == :ok
      end)

    assert log =~ second
  end
end

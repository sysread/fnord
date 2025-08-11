defmodule UI.UITest do
  @moduledoc """
  Unit tests for UI.clean_detail/1 and UI.iodata?/1 functions.
  """

  use Fnord.TestCase

  alias UI

  describe "clean_detail/1" do
    test "returns empty string for nil input" do
      assert UI.clean_detail(nil) == ""
    end

    test "returns unchanged binary iodata for valid iodata input" do
      assert UI.clean_detail("hello world") == "hello world"
    end

    test "returns unchanged charlist iodata for valid iodata input" do
      assert UI.clean_detail(~c"hello") == "hello"
    end

    test "returns unchanged nested iodata for valid iodata input" do
      nested = ["foo", [32, "bar"]]
      assert UI.clean_detail(nested) == "foo bar"
    end

    test "prefixes newline for multi-line binary input" do
      input = "line1\nline2\nline3"
      assert UI.clean_detail(input) == "\nline1\nline2\nline3"
    end

    test "inspects non-iodata input and returns its string representation" do
      assert UI.clean_detail(1024) == "1024"
    end

    test "prefixes newline for inspected multi-line output" do
      detail = Enum.into(1..20, %{}, fn i -> {i, List.duplicate(i, i)} end)
      result = UI.clean_detail(detail)
      assert String.starts_with?(result, "\n%{")
      assert String.contains?(result, "%{\n")
    end
  end

  describe "iodata?/1" do
    test "returns true for valid binary iodata" do
      assert UI.iodata?("hello")
    end

    test "returns true for valid integer byte" do
      assert UI.iodata?(255)
    end

    test "returns false for integer outside byte range" do
      refute UI.iodata?(-1)
      refute UI.iodata?(256)
    end

    test "returns true for empty list" do
      assert UI.iodata?([])
    end

    test "returns true for nested valid iodata list" do
      nested = [65, "BC", [67, "D"]]
      assert UI.iodata?(nested)
    end

    test "returns false for nested invalid iodata list" do
      invalid = [65, :atom, [67, "D"]]
      refute UI.iodata?(invalid)
    end

    test "returns false for improper list" do
      improper = [65 | 66]
      refute UI.iodata?(improper)
    end
  end

  describe "with_notification_timeout/2" do
    test "returns function result when function completes quickly" do
      # Mock Notifier to ensure it's not called
      :meck.new(Notifier, [:passthrough])
      :meck.expect(Notifier, :notify, fn _title, _message, _opts -> :ok end)

      result = UI.with_notification_timeout(fn -> :quick_result end, "test message", 1000)
      
      assert result == :quick_result
      # Verify notification was not sent
      assert :meck.called(Notifier, :notify, :_) == false

      :meck.unload(Notifier)
    end

    test "sends notification after timeout but still returns result" do
      # Mock Notifier
      :meck.new(Notifier, [:passthrough])
      :meck.expect(Notifier, :notify, fn _title, _message, _opts -> :ok end)

      # Function that delays longer than timeout
      delayed_func = fn ->
        Process.sleep(200)  
        :delayed_result
      end

      result = UI.with_notification_timeout(delayed_func, "test message", 100)
      
      assert result == :delayed_result
      # Verify notification was sent
      assert :meck.called(Notifier, :notify, ["Fnord", "test message", [urgency: "critical"]])

      :meck.unload(Notifier)
    end

    test "cancels notification if function completes before timeout" do
      # Mock Notifier
      :meck.new(Notifier, [:passthrough])
      :meck.expect(Notifier, :notify, fn _title, _message, _opts -> :ok end)

      # Function that completes just before timeout
      fast_func = fn ->
        Process.sleep(50)  
        :fast_result
      end

      result = UI.with_notification_timeout(fast_func, "test message", 100)
      
      assert result == :fast_result
      # Verify notification was not sent
      assert :meck.called(Notifier, :notify, :_) == false

      :meck.unload(Notifier)
    end

    test "dismisses notification when function completes after timeout" do
      # Mock Notifier
      :meck.new(Notifier, [:passthrough])
      :meck.expect(Notifier, :notify, fn _title, _message, _opts -> :ok end)
      :meck.expect(Notifier, :dismiss, fn _group -> :ok end)

      # Function that delays longer than timeout
      delayed_func = fn ->
        Process.sleep(200)  
        :delayed_result
      end

      result = UI.with_notification_timeout(delayed_func, "test message", 100)
      
      assert result == :delayed_result
      # Verify notification was sent and then dismissed
      assert :meck.called(Notifier, :notify, ["Fnord", "test message", [urgency: "critical"]])
      assert :meck.called(Notifier, :dismiss, ["fnord"])

      :meck.unload(Notifier)
    end
  end
end

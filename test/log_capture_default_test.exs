defmodule Fnord.TestCase.LoggingBehaviorTest do
  use Fnord.TestCase
  require Logger

  @moduletag :capture_log

  test "default Logger.level is :warning" do
    # By default, Fnord.TestCase should configure Logger.level to :warning
    assert Logger.level() == :warning
  end

  test "set_log_level/1 overrides default level" do
    # Using the helper should temporarily set the Logger level
    set_log_level(:debug)
    assert Logger.level() == :debug
  end

  test "Logger.error is captured by capture_log tag by default" do
    log = ExUnit.CaptureLog.capture_log(fn -> Logger.error("oops") end)
    assert log =~ "oops"
  end
end

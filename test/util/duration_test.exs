defmodule Util.DurationTest do
  use Fnord.TestCase

  describe "format/1 :natural" do
    test "sub-minute and zero" do
      assert Util.Duration.format(0) == "0 seconds"
      assert Util.Duration.format(1) == "1 second"
      assert Util.Duration.format(30) == "30 seconds"
      assert Util.Duration.format(59) == "59 seconds"
    end

    test "minutes range" do
      assert Util.Duration.format(60) == "1 minute"
      assert Util.Duration.format(75) == "1 minute, 15 seconds"
      assert Util.Duration.format(330) == "5 minutes, 30 seconds"
      assert Util.Duration.format(3599) == "59 minutes, 59 seconds"
    end

    test "hours range" do
      assert Util.Duration.format(3600) == "1 hour"
      assert Util.Duration.format(3661) == "1 hour, 1 minute, 1 second"
      assert Util.Duration.format(86399) == "23 hours, 59 minutes, 59 seconds"
      assert Util.Duration.format(86400) == "24 hours"
    end
  end

  describe "format/2 :compact" do
    test "edge cases" do
      assert Util.Duration.format(0, :compact) == "0s"
      assert Util.Duration.format(59, :compact) == "59s"
      assert Util.Duration.format(60, :compact) == "1:00"
      assert Util.Duration.format(75, :compact) == "1:15"
      assert Util.Duration.format(330, :compact) == "5:30"
      assert Util.Duration.format(3599, :compact) == "59:59"
      assert Util.Duration.format(3600, :compact) == "1:00:00"
      assert Util.Duration.format(3661, :compact) == "1:01:01"
    end
  end
end

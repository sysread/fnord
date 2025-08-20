defmodule AI.Tools.Shell.AllowedTest do
  use Fnord.TestCase, async: true
  alias AI.Tools.Shell.Allowed

  describe "allowed?/2" do
    test "allows basic allow-listed commands" do
      Allowed.preapproved_cmds()
      |> Enum.each(fn full_cmd ->
        bits = String.split(full_cmd, " ")
        cmd = hd(bits)
        assert Allowed.allowed?(cmd, bits)
      end)
    end

    test "allows git log but not git remote" do
      assert Allowed.allowed?("git", ["git", "log"])
      refute Allowed.allowed?("git", ["git", "remote"])
    end

    test "rejects non-existent executables" do
      refute Allowed.allowed?("not_a_real_cmd", ["not_a_real_cmd"])
    end
  end
end

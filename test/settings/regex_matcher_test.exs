defmodule Settings.RegexMatcherTest do
  use Fnord.TestCase, async: false
  alias Settings.Approvals.RegexMatcher

  describe "compile_patterns/1" do
    test "handles list and non-list input" do
      patterns = RegexMatcher.compile_patterns(["^a+$"])
      assert [%Regex{source: "^a+$"}] = patterns
      assert RegexMatcher.compile_patterns(nil) == []
    end
  end

  describe "matches?/2" do
    test "returns true for matching and false otherwise" do
      assert RegexMatcher.matches?("^foo.*", "foobar")
      refute RegexMatcher.matches?("^foo$", "foobar")
      # non-binary inputs should return false
      refute RegexMatcher.matches?(123, "123")
      refute RegexMatcher.matches?("123", 123)
    end
  end
end

defmodule Services.Approvals.Shell.PrefixTest do
  use ExUnit.Case, async: true
  alias Services.Approvals.Shell.Prefix

  describe "extract/2 for known families" do
    test "git --no-pager log → \"git log\"" do
      assert Prefix.extract("git", ["--no-pager", "log"]) == "git log"
    end

    test "git -c color.ui=always log → \"git log\"" do
      assert Prefix.extract("git", ["-c", "color.ui=always", "log"]) == "git log"
    end

    test "git -C . log → \"git log\"" do
      assert Prefix.extract("git", ["-C", ".", "log"]) == "git log"
    end

    test "git --git-dir .git log → \"git log\"" do
      assert Prefix.extract("git", ["--git-dir", ".git", "log"]) == "git log"
    end

    test "kubectl -n foo get pods → \"kubectl get\"" do
      assert Prefix.extract("kubectl", ["-n", "foo", "get", "pods"]) == "kubectl get"
    end

    test "git --version (no subcommand) → \"git\"" do
      assert Prefix.extract("git", ["--version"]) == "git"
    end
  end

  describe "extract/2 for non-family commands" do
    test "foo -x bar → \"foo\"" do
      assert Prefix.extract("foo", ["-x", "bar"]) == "foo"
    end
  end
end

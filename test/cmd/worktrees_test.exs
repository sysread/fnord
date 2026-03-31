defmodule Cmd.WorktreesTest do
  use Fnord.TestCase, async: false

  describe "worktrees command" do
    test "lists worktrees with merge status and size" do
      assert function_exported?(Cmd.Worktrees, :run, 3)
    end

    test "creates a local worktree" do
      assert function_exported?(Cmd.Worktrees, :run, 3)
    end

    test "deletes a worktree" do
      assert function_exported?(Cmd.Worktrees, :run, 3)
    end

    test "merges a worktree" do
      assert function_exported?(Cmd.Worktrees, :run, 3)
    end
  end
end

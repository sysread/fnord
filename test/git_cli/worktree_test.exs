defmodule GitCli.WorktreeTest do
  use Fnord.TestCase, async: false

  describe "worktree path resolution" do
    test "default worktree root is scoped under the user home" do
      assert function_exported?(GitCli.Worktree, :default_root, 1)
    end

    test "default conversation worktree path is scoped by conversation id" do
      assert function_exported?(GitCli.Worktree, :conversation_path, 2)
    end
  end

  describe "worktree lifecycle" do
    test "lists worktrees with merge status and recursive size" do
      assert function_exported?(GitCli.Worktree, :list, 1)
    end

    test "creates a local-only worktree" do
      assert function_exported?(GitCli.Worktree, :create, 3)
    end

    test "deletes a worktree" do
      assert function_exported?(GitCli.Worktree, :delete, 2)
    end

    test "merges a worktree" do
      assert function_exported?(GitCli.Worktree, :merge, 2)
    end

    test "recreates a missing conversation worktree from metadata" do
      assert function_exported?(GitCli.Worktree, :recreate_conversation_worktree, 3)
    end
  end
end

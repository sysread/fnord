defmodule Cmd.WorktreesTest do
  use Fnord.TestCase, async: false

  setup do
    :ok = safe_meck_new(GitCli.Worktree, [:passthrough])
    :ok = safe_meck_new(Store, [:passthrough])

    on_exit(fn ->
      safe_meck_unload(GitCli.Worktree)
      safe_meck_unload(Store)
    end)

    :ok
  end

  describe "worktrees command" do
    test "lists worktrees with merge status and size" do
      :meck.expect(GitCli.Worktree, :project_root, fn -> {:ok, "/repo"} end)

      :meck.expect(GitCli.Worktree, :list, fn "/repo" ->
        {:ok,
         [
           %{
             path: "/repo/wt-a",
             branch: "main",
             merge_status: :ahead,
             size: 1024
           }
         ]}
      end)

      assert capture_io(fn ->
               assert :ok == Cmd.Worktrees.run(%{}, [:list], [])
             end) == "/repo/wt-a\tmain\tahead\t1024\n"
    end

    test "creates a local worktree" do
      :meck.expect(Store, :get_project, fn -> {:ok, %{name: "demo"}} end)

      :meck.expect(GitCli.Worktree, :create, fn "demo", "conv-1", "feat" ->
        {:ok, %{path: "/repo/wt-feat"}}
      end)

      assert :ok == Cmd.Worktrees.run(%{conversation: "conv-1", branch: "feat"}, [:create], [])
    end

    test "deletes a worktree" do
      :meck.expect(GitCli.Worktree, :project_root, fn -> {:ok, "/repo"} end)
      :meck.expect(GitCli.Worktree, :delete, fn "/repo", "/tmp/wt" -> {:ok, :ok} end)

      assert :ok == Cmd.Worktrees.run(%{path: "/tmp/wt"}, [:delete], [])
    end

    test "merges a worktree" do
      :meck.expect(GitCli.Worktree, :project_root, fn -> {:ok, "/repo"} end)
      :meck.expect(GitCli.Worktree, :merge, fn "/repo", "/tmp/wt" -> {:ok, :ok} end)

      assert :ok == Cmd.Worktrees.run(%{path: "/tmp/wt"}, [:merge], [])
    end
  end

  defp safe_meck_new(module, options) do
    safe_meck_unload(module)
    :meck.new(module, options)
  end

  defp safe_meck_unload(module) do
    try do
      :meck.unload(module)
    catch
      _, _ -> :ok
    end

    :ok
  end
end

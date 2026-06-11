defmodule Cmd.PrimeTest do
  # async: false - the delegated Cmd.Ask.run boots ad-hoc GenServers whose
  # init code calls Mox-backed facades; those processes are outside
  # private-mode ownership, so this file needs global Mox.
  use Fnord.TestCase, async: false

  describe "run/3" do
    setup do
      mock_project("test_proj")

      # Prime delegates to the full ask flow; script git state through the
      # facades so the real GitCli does not see the repo this suite runs in.
      mock_git_cli()
      Mox.stub(GitCli.Mock, :is_worktree?, fn -> false end)
      Mox.stub(GitCli.Mock, :is_git_repo?, fn -> false end)

      :ok
    end

    test "runs the ask flow with the primer question (happy path)" do
      test_pid = self()

      canned_agent(fn AI.Agent.Coordinator, args ->
        send(test_pid, {:question, args.question})
        {:ok, %{usage: 1, context: 2, last_response: "primed"}}
      end)

      capture_all(fn ->
        assert :ok == Cmd.Prime.run(%{}, [], [])
      end)

      assert_received {:question, question}
      assert String.starts_with?(question, "Please provide an overview of the current project.")
    end

    test "propagates errors from the ask flow" do
      # An invalid --worktree fails ask's validation before the coordinator
      # runs; Prime must surface that error untouched.
      capture_all(fn ->
        assert {:error, :invalid_worktree} = Cmd.Prime.run(%{worktree: "/nope"}, [], [])
      end)
    end
  end
end

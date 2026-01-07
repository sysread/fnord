defmodule Cmd.Ask.WorktreeTest do
  use Fnord.TestCase, async: false

  setup do
    project = mock_project("ask_worktree_test")
    {:ok, project: project}
  end

  setup do
    :meck.new(Services.Conversation, [:no_link, :passthrough, :non_strict])
    on_exit(fn -> :meck.unload(Services.Conversation) end)

    :meck.new(GitCli, [:no_link, :passthrough, :non_strict])
    on_exit(fn -> :meck.unload(GitCli) end)

    :meck.new(UI, [:no_link, :passthrough, :non_strict])
    on_exit(fn -> :meck.unload(UI) end)

    :ok
  end

  test "valid --worktree is applied" do
    :meck.expect(Services.Conversation, :get_response, fn _pid, _opts ->
      {:ok,
       %{
         usage: 42,
         context: 42,
         last_response: "How now brown bureaucrat?"
       }}
    end)

    assert Settings.get_project_root_override() == nil

    {:ok, dir} = tmpdir()

    {_stdout, _stderr} =
      capture_all(fn ->
        assert :ok =
                 Cmd.Ask.run(
                   %{
                     worktree: dir,
                     question: "hello"
                   },
                   [],
                   []
                 )
      end)

    assert Settings.get_project_root_override() == dir
  end

  test "invalid --worktree errors early and leaves no override" do
    assert Settings.get_project_root_override() == nil
    bad = "/nope"

    assert {:error, :invalid_worktree} =
             Cmd.Ask.run(
               %{
                 worktree: bad,
                 question: "hello"
               },
               [],
               []
             )

    assert Settings.get_project_root_override() == nil
  end

  test "missing --worktree: prompts and applies override when accepted" do
    # create a fake worktree root
    {:ok, wt_root} = tmpdir()

    # Stub GitCli to simulate a mismatched worktree
    :meck.expect(GitCli, :is_worktree?, fn -> true end)
    :meck.expect(GitCli, :worktree_root, fn -> wt_root end)

    # Stub UI to simulate TTY and user acceptance
    :meck.expect(UI, :is_tty?, fn -> true end)
    :meck.expect(UI, :confirm, fn _msg, _default -> true end)

    # Avoid real AI calls
    :meck.expect(Services.Conversation, :get_response, fn _pid, _opts ->
      {:ok, %{usage: 0, context: 0, last_response: "ok"}}
    end)

    # No override initially
    assert Settings.get_project_root_override() == nil

    # Run in edit mode without --worktree
    capture_all(fn ->
      assert :ok = Cmd.Ask.run(%{question: "Q", edit: true}, [], [])
    end)

    # Override should now be set to worktree root
    assert Settings.get_project_root_override() == wt_root
  end

  test "missing --worktree: prompts and does not apply override when declined" do
    # create a fake worktree root
    {:ok, wt_root} = tmpdir()

    # Stub GitCli to simulate a mismatched worktree
    :meck.expect(GitCli, :is_worktree?, fn -> true end)
    :meck.expect(GitCli, :worktree_root, fn -> wt_root end)

    # Stub UI to simulate TTY and user decline
    :meck.expect(UI, :is_tty?, fn -> true end)
    :meck.expect(UI, :confirm, fn _msg, _default -> false end)

    # Avoid real AI calls
    :meck.expect(Services.Conversation, :get_response, fn _pid, _opts ->
      {:ok, %{usage: 0, context: 0, last_response: "ok"}}
    end)

    # No override initially
    assert Settings.get_project_root_override() == nil

    # Run in edit mode without --worktree
    capture_all(fn ->
      assert :ok = Cmd.Ask.run(%{question: "Q", edit: true}, [], [])
    end)

    # Override should remain nil
    assert Settings.get_project_root_override() == nil
  end
end

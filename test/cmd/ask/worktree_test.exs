defmodule Cmd.Ask.Worktree.Test do
  use Fnord.TestCase
  import ExUnit.CaptureIO

  setup do
    project = mock_project("ask_worktree_test")
    {:ok, project: project}
  end

  setup do
    :meck.new(Services.Conversation, [:no_link, :passthrough, :non_strict])
    on_exit(fn -> :meck.unload(Services.Conversation) end)
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

    capture_io(fn ->
      assert :ok =
               Cmd.Ask.run(
                 %{
                   worktree: dir,
                   question: "hello",
                   rounds: 1
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
                 question: "hello",
                 rounds: 1
               },
               [],
               []
             )

    assert Settings.get_project_root_override() == nil
  end
end

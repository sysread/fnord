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

  test "explicit --worktree is rejected when the conversation already has one" do
    :meck.expect(Services.Conversation, :get_conversation_meta, fn _pid ->
      {:ok, %{worktree: %{path: "/tmp/existing", branch: "feature", base_branch: "main"}}}
    end)

    assert {:error, {:conversation_worktree_exists, _}} =
             Cmd.Ask.run(
               %{
                 worktree: "/tmp/another",
                 question: "hello"
               },
               [],
               []
             )
  end

  test "missing stored worktree is recreated without reinterpreting --worktree" do
    {:ok, dir} = tmpdir()

    :meck.expect(Services.Conversation, :get_conversation_meta, fn _pid ->
      {:ok, %{worktree: %{path: dir, branch: "feature", base_branch: "main"}}}
    end)

    :meck.expect(GitCli.Worktree, :recreate_conversation_worktree, fn _project,
                                                                      _conversation,
                                                                      _meta ->
      {:ok, %{path: dir, branch: "feature", base_branch: "main"}}
    end)

    :meck.expect(Services.Conversation, :update_conversation_meta, fn _pid, _meta ->
      :ok
    end)

    :meck.expect(Services.Conversation, :get_response, fn _pid, _opts ->
      {:ok, %{usage: 0, context: 0, last_response: "ok"}}
    end)

    assert Settings.get_project_root_override() == nil

    capture_all(fn ->
      assert :ok = Cmd.Ask.run(%{question: "Q", edit: true}, [], [])
    end)

    assert Settings.get_project_root_override() == dir
  end

  test "conversation without a worktree binds an explicit existing --worktree" do
    {:ok, dir} = tmpdir()

    :meck.expect(Services.Conversation, :get_conversation_meta, fn _pid ->
      {:ok, %{}}
    end)

    :meck.expect(Services.Conversation, :update_conversation_meta, fn _pid, meta ->
      assert meta == %{worktree: %{path: dir, branch: nil, base_branch: nil}}
      :ok
    end)

    :meck.expect(Services.Conversation, :get_response, fn _pid, _opts ->
      {:ok, %{usage: 0, context: 0, last_response: "ok"}}
    end)

    assert Settings.get_project_root_override() == nil

    capture_all(fn ->
      assert :ok = Cmd.Ask.run(%{question: "Q", worktree: dir}, [], [])
    end)

    assert Settings.get_project_root_override() == dir
  end
end

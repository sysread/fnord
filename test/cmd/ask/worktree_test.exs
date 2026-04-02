defmodule Cmd.Ask.WorktreeTest do
  use Fnord.TestCase, async: false

  setup do
    project = mock_project("ask_worktree_test")
    {:ok, project: project}
  end

  setup do
    safe_meck_new(Services.Conversation, [:no_link, :passthrough, :non_strict])
    on_exit(fn -> safe_meck_unload(Services.Conversation) end)

    safe_meck_new(GitCli, [:no_link, :passthrough, :non_strict])
    on_exit(fn -> safe_meck_unload(GitCli) end)

    safe_meck_new(UI, [:no_link, :passthrough, :non_strict])
    on_exit(fn -> safe_meck_unload(UI) end)

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
      %{worktree: %{path: "/tmp/existing", branch: "feature", base_branch: "main"}}
    end)

    assert {:error, :invalid_worktree} =
             Cmd.Ask.run(
               %{
                 worktree: "/tmp/another",
                 question: "hello"
               },
               [],
               []
             )
  end

  test "explicit rejected --worktree restores the stored worktree override" do
    {:ok, explicit_dir} = tmpdir()
    stored_dir = Path.join(Settings.get_user_home(), "stored-conversation-worktree")

    :meck.expect(Services.Conversation, :get_conversation_meta, fn _pid ->
      %{worktree: %{path: stored_dir, branch: "feature", base_branch: "main"}}
    end)

    assert {:error, {:conversation_worktree_exists, ^stored_dir}} =
             Cmd.Ask.run(
               %{
                 worktree: explicit_dir,
                 question: "hello"
               },
               [],
               []
             )

    assert Settings.get_project_root_override() == stored_dir
  end

  test "missing stored worktree is recreated without reinterpreting --worktree" do
    dir = Path.join(Settings.get_user_home(), "missing-conversation-worktree")
    meta = %{path: dir, branch: "feature", base_branch: "main"}

    :meck.expect(Services.Conversation, :get_conversation_meta, fn _pid ->
      %{worktree: meta}
    end)

    :meck.expect(Services.Conversation, :get_id, fn _pid -> "conv-1" end)

    :meck.expect(GitCli.Worktree, :recreate_conversation_worktree, fn "ask_worktree_test",
                                                                      "conv-1",
                                                                      ^meta ->
      send(self(), :recreate_called)
      File.mkdir_p!(dir)
      {:ok, %{path: dir, branch: "feature", base_branch: "main"}}
    end)

    :meck.expect(Services.Conversation, :upsert_conversation_meta, fn _pid, update ->
      assert update == %{worktree: %{path: dir, branch: "feature", base_branch: "main"}}
      :ok
    end)

    :meck.expect(Services.Conversation, :get_response, fn _pid, _opts ->
      {:ok, %{usage: 0, context: 0, last_response: "ok"}}
    end)

    assert Settings.get_project_root_override() == nil

    capture_all(fn ->
      assert :ok = Cmd.Ask.run(%{question: "Q", edit: true}, [], [])
    end)

    assert_received :recreate_called
    assert Settings.get_project_root_override() == dir
  end

  test "conversation without a worktree binds an explicit existing --worktree" do
    {:ok, dir} = tmpdir()

    :meck.expect(Services.Conversation, :get_conversation_meta, fn _pid ->
      %{}
    end)

    :meck.expect(Services.Conversation, :upsert_conversation_meta, fn _pid, meta ->
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

  defp safe_meck_new(module, opts) do
    safe_meck_unload(module)
    :meck.new(module, opts)
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

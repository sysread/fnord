defmodule Cmd.AskTest do
  use Fnord.TestCase, async: false

  setup do
    Services.Globals.delete_env(:fnord, :auto_policy)

    # Ensure settings directory exists without deleting it to avoid races
    settings_file = Settings.settings_file()
    settings_dir = Path.dirname(settings_file)
    File.mkdir_p!(settings_dir)

    # Ensure lock directory parent exists so FileLock can create locks without errors
    lock_dir = settings_file <> ".lock"
    lock_parent = Path.dirname(lock_dir)
    File.mkdir_p!(lock_parent)

    :ok
  end

  test "default auto policy is deny after 180_000 ms when no flags provided" do
    opts = %{}
    # Apply the default policy
    assert :ok == apply(Cmd.Ask, :set_auto_policy, [opts])
    assert Settings.get_auto_policy() == {:deny, 180_000}
  end

  test "auto deny override uses provided seconds" do
    opts = %{auto_deny_after: 5}
    # Validate flags first
    assert :ok == apply(Cmd.Ask, :validate_auto, [opts])
    assert :ok == apply(Cmd.Ask, :set_auto_policy, [opts])
    assert Settings.get_auto_policy() == {:deny, 5_000}
  end

  test "auto approve override uses provided seconds" do
    opts = %{auto_approve_after: 2}
    assert :ok == apply(Cmd.Ask, :validate_auto, [opts])
    assert :ok == apply(Cmd.Ask, :set_auto_policy, [opts])
    assert Settings.get_auto_policy() == {:approve, 2_000}
  end

  test "mutually exclusive auto flags returns error" do
    opts = %{auto_approve_after: 1, auto_deny_after: 2}
    assert {:error, _msg} = apply(Cmd.Ask, :validate_auto, [opts])
  end

  test "invalid auto flag values return error" do
    assert {:error, _} = apply(Cmd.Ask, :validate_auto, [%{auto_approve_after: 0}])
    assert {:error, _} = apply(Cmd.Ask, :validate_auto, [%{auto_deny_after: -1}])
  end

  describe "run/3 exception handling" do
    setup do
      # safe_meck_new tolerates a previously-leaked mock by unloading it
      # first, preventing :already_started errors when this setup runs after
      # an unrelated test that mocked the same module without cleanup.
      :ok = safe_meck_new(Services.Conversation, [:passthrough])
      :ok = safe_meck_new(GitCli, [:passthrough])
      :meck.expect(Services.Conversation, :start_link, fn _args -> raise "boom" end)
      :meck.expect(GitCli, :is_worktree?, fn -> false end)
      :meck.validate(Services.Conversation)

      on_exit(fn ->
        for mod <- [Services.Conversation, GitCli] do
          safe_meck_unload(mod)
        end
      end)

      :ok
    end

    test "propagates start_link exceptions (outside try)" do
      opts = %{question: "whoops?"}

      assert_raise RuntimeError, "boom", fn ->
        Cmd.Ask.run(opts, [], [])
      end
    end
  end

  describe "run/3 missing conversations" do
    setup do
      :ok = safe_meck_new(UI, [:passthrough])
      :ok = safe_meck_new(Store.Project.Conversation, [:passthrough])
      :ok = safe_meck_new(GitCli, [:passthrough])

      :meck.expect(UI, :quiet?, fn -> true end)
      :meck.expect(UI, :error, fn _ -> :ok end)
      :meck.expect(UI, :spin, fn _label, fun -> fun.() end)
      :meck.expect(GitCli, :is_worktree?, fn -> false end)
      :meck.expect(Store.Project.Conversation, :new, fn id -> %{id: id} end)
      :meck.expect(Store.Project.Conversation, :exists?, fn _ -> false end)

      on_exit(fn ->
        Enum.each([UI, Store.Project.Conversation, GitCli], fn mod ->
          try do
            :meck.unload(mod)
          catch
            _, _ -> :ok
          end
        end)
      end)

      :ok
    end

    test "reports the missing fork conversation id" do
      assert {:error, :conversation_not_found} =
               Cmd.Ask.run(%{question: "hello", fork: "fork-404"}, [], [])

      assert :meck.called(UI, :error, ["Conversation ID fork-404 not found"])
    end
  end

  describe "run/3 save failures" do
    setup do
      :ok = safe_meck_new(Store, [:passthrough])
      :ok = safe_meck_new(Outputs, [:passthrough])
      :ok = safe_meck_new(UI, [:passthrough])
      :ok = safe_meck_new(GitCli, [:passthrough])
      :ok = safe_meck_new(Services.Conversation, [:passthrough])
      :ok = safe_meck_new(Services.Task, [:passthrough])
      :ok = safe_meck_new(Memory, [:passthrough])
      :ok = safe_meck_new(Clipboard, [:passthrough])
      :ok = safe_meck_new(Notifier, [:passthrough])

      :meck.expect(GitCli, :is_worktree?, fn -> false end)

      on_exit(fn ->
        Enum.each(
          [
            Store,
            Outputs,
            UI,
            GitCli,
            Services.Conversation,
            Services.Task,
            Memory,
            Clipboard,
            Notifier
          ],
          fn mod ->
            try do
              :meck.unload(mod)
            catch
              _, _ -> :ok
            end
          end
        )
      end)

      :ok
    end

    test "logs a save failure instead of crashing when output persistence fails" do
      project = Store.Project.new("demo", "/tmp/demo")

      :meck.expect(Store, :get_project, fn -> {:ok, project} end)
      :meck.expect(Outputs, :save, fn _project_name, _response, _opts -> {:error, :disk_full} end)
      :meck.expect(UI, :quiet?, fn -> true end)
      :meck.expect(UI, :debug, fn _, _ -> :ok end)
      :meck.expect(UI, :error, fn _ -> :ok end)
      :meck.expect(UI, :report_step, fn _, _ -> :ok end)
      :meck.expect(UI, :say, fn _ -> :ok end)
      :meck.expect(UI, :flush, fn -> :ok end)
      :meck.expect(UI, :warn, fn _ -> :ok end)
      :meck.expect(UI, :spin, fn _label, fun -> fun.() end)
      :meck.expect(Services.Conversation, :start_link, fn _ -> {:ok, self()} end)
      :meck.expect(Services.Conversation, :get_id, fn _ -> "conv-1" end)
      :meck.expect(Services.Conversation, :get_conversation_meta, fn _ -> %{} end)

      :meck.expect(Services.Conversation, :get_response, fn _, _ ->
        {:ok, %{usage: 1, context: 2, last_response: "hello"}}
      end)

      :meck.expect(Services.Conversation, :save, fn _ ->
        {:ok, %{id: "conv-1", store_path: "/tmp/conv-1.json"}}
      end)

      :meck.expect(Services.Task, :start_link, fn opts ->
        assert Keyword.get(opts, :conversation_pid) == self()
        {:ok, self()}
      end)

      :meck.expect(Memory, :init, fn -> :ok end)
      :meck.expect(Memory, :list, fn _ -> {:ok, []} end)
      :meck.expect(Memory, :search_stats, fn -> nil end)
      :meck.expect(Clipboard, :copy, fn _ -> :ok end)
      :meck.expect(Notifier, :notify, fn _, _ -> :ok end)

      {_stdout, stderr} =
        capture_all(fn ->
          assert :ok == Cmd.Ask.run(%{question: "hello", save: true}, [], [])
        end)

      assert stderr =~ "(no file changes during this session)"
      assert :meck.called(UI, :error, ["Failed to save output: disk_full"])
    end

    test "omits clipboard success text when copying the conversation id fails" do
      project = Store.Project.new("demo", "/tmp/demo")
      parent = self()

      :meck.expect(Store, :get_project, fn -> {:ok, project} end)
      :meck.expect(UI, :quiet?, fn -> true end)
      :meck.expect(UI, :debug, fn _, _ -> :ok end)
      :meck.expect(UI, :error, fn _ -> :ok end)
      :meck.expect(UI, :report_step, fn _, _ -> :ok end)

      :meck.expect(UI, :say, fn message ->
        send(parent, {:ui_say, message})
        :ok
      end)

      :meck.expect(UI, :flush, fn -> :ok end)
      :meck.expect(UI, :warn, fn _ -> :ok end)
      :meck.expect(UI, :spin, fn _label, fun -> fun.() end)
      :meck.expect(Services.Conversation, :start_link, fn _ -> {:ok, self()} end)
      :meck.expect(Services.Conversation, :get_id, fn _ -> "conv-1" end)
      :meck.expect(Services.Conversation, :get_conversation_meta, fn _ -> %{} end)

      :meck.expect(Services.Conversation, :get_response, fn _, _ ->
        {:ok, %{usage: 1, context: 2, last_response: "hello"}}
      end)

      :meck.expect(Services.Conversation, :save, fn _ ->
        {:ok, %{id: "conv-1", store_path: "/tmp/conv-1.json"}}
      end)

      :meck.expect(Services.Task, :start_link, fn opts ->
        assert Keyword.get(opts, :conversation_pid) == self()
        {:ok, self()}
      end)

      :meck.expect(Memory, :init, fn -> :ok end)
      :meck.expect(Memory, :list, fn _ -> {:ok, []} end)
      :meck.expect(Memory, :search_stats, fn -> nil end)
      :meck.expect(Clipboard, :copy, fn _ -> {:error, :unavailable} end)
      :meck.expect(Notifier, :notify, fn _, _ -> :ok end)

      {_stdout, stderr} =
        capture_all(fn ->
          assert :ok == Cmd.Ask.run(%{question: "hello"}, [], [])
        end)

      assert stderr =~ "(no file changes during this session)"
      assert_receive {:ui_say, output}
      assert output =~ "Conversation saved with ID conv-1"
      refute output =~ "copied to clipboard"
    end
  end

  describe "run/3 merged worktree reporting" do
    setup do
      # Store.Project must be in this list because the tests below
      # :meck.expect(Store.Project, :index_status, ...). Calling :meck.expect
      # on a module that has not been :meck.new'd creates an IMPLICIT
      # non-passthrough mock that leaks past the test boundary - subsequent
      # tests in the suite (Cmd.FilesTest, Cmd.IndexTest, Store.Project.EntryTest,
      # Cmd.SummaryTest, etc.) call Store.Project.index_status as part of
      # their indexing setup and get back the empty mock result, which made
      # them fail with "No files to index" / "No conversations to index".
      :ok = safe_meck_new(Store, [:passthrough])
      :ok = safe_meck_new(Store.Project, [:passthrough])
      :ok = safe_meck_new(Settings, [:passthrough])
      :ok = safe_meck_new(UI, [:passthrough])
      :ok = safe_meck_new(GitCli, [:passthrough])
      :ok = safe_meck_new(GitCli.Worktree, [:passthrough])
      :ok = safe_meck_new(GitCli.Worktree.Review, [:passthrough])
      :ok = safe_meck_new(Services.Conversation, [:passthrough])
      :ok = safe_meck_new(Services.Task, [:passthrough])
      :ok = safe_meck_new(Memory, [:passthrough])
      :ok = safe_meck_new(Clipboard, [:passthrough])
      :ok = safe_meck_new(Notifier, [:passthrough])

      on_exit(fn ->
        Settings.set_project_root_override(nil)

        Enum.each(
          [
            Store,
            Store.Project,
            Settings,
            UI,
            GitCli,
            GitCli.Worktree,
            GitCli.Worktree.Review,
            Services.Conversation,
            Services.Task,
            Memory,
            Clipboard,
            Notifier
          ],
          fn mod ->
            try do
              :meck.unload(mod)
            catch
              _, _ -> :ok
            end
          end
        )
      end)

      :ok
    end

    test "clears the final worktree summary after interactive merge cleanup" do
      {:ok, worktree_dir} = tmpdir()
      Settings.set_project_root_override(worktree_dir)
      parent = self()
      project = Store.Project.new("demo", "/tmp/demo")
      settings = Settings.new()

      :meck.expect(Settings, :get_project_data, fn ^settings, "demo" ->
        %{"root" => "/tmp/demo"}
      end)

      :meck.expect(Store, :get_project, fn -> {:ok, project} end)
      :meck.expect(Store.Project, :index_status, fn _ -> %{new: [], stale: [], deleted: []} end)
      :meck.expect(UI, :quiet?, fn -> true end)
      :meck.expect(UI, :debug, fn _, _ -> :ok end)
      :meck.expect(UI, :error, fn _ -> :ok end)
      :meck.expect(UI, :report_step, fn _, _ -> :ok end)
      :meck.expect(UI, :flush, fn -> :ok end)
      :meck.expect(UI, :warn, fn _ -> :ok end)
      :meck.expect(UI, :spin, fn _label, fun -> fun.() end)

      :meck.expect(UI, :say, fn message ->
        send(parent, {:ui_say, message})
        :ok
      end)

      :meck.expect(GitCli, :is_worktree?, fn -> false end)
      :meck.expect(GitCli.Worktree, :fnord_managed?, fn "demo", ^worktree_dir -> true end)
      :meck.expect(GitCli.Worktree, :has_uncommitted_changes?, fn ^worktree_dir -> true end)

      :meck.expect(GitCli.Worktree, :has_changes_to_merge?, fn "/tmp/demo",
                                                               ^worktree_dir,
                                                               "feat",
                                                               "main" ->
        true
      end)

      :meck.expect(GitCli.Worktree.Review, :interactive_review, fn "/tmp/demo", meta, _opts ->
        assert meta.path == worktree_dir
        assert meta.branch == "feat"
        assert meta.base_branch == "main"
        {:cleaned_up, {"aaa000", "abc123"}, :interactive}
      end)

      :meck.expect(GitCli.Worktree, :log_oneline, fn _root, "aaa000", "abc123" ->
        ["abc123 add feature file"]
      end)

      :meck.expect(Services.Conversation, :start_link, fn _ -> {:ok, self()} end)
      :meck.expect(Services.Conversation, :get_id, fn _ -> "conv-1" end)

      :meck.expect(Services.Conversation, :get_conversation_meta, fn _ ->
        %{worktree: %{path: worktree_dir, branch: "feat", base_branch: "main"}}
      end)

      :meck.expect(Services.Conversation, :upsert_conversation_meta, fn _, %{worktree: nil} ->
        :ok
      end)

      :meck.expect(Services.Conversation, :get_response, fn _, _ ->
        {:ok, %{usage: 1, context: 2, last_response: "hello", editing_tools_used: true}}
      end)

      :meck.expect(Services.Conversation, :save, fn _ ->
        {:ok, %{id: "conv-1", store_path: "/tmp/conv-1.json"}}
      end)

      :meck.expect(Services.Task, :start_link, fn opts ->
        assert Keyword.get(opts, :conversation_pid) == self()
        {:ok, self()}
      end)

      :meck.expect(Memory, :init, fn -> :ok end)
      :meck.expect(Memory, :list, fn _ -> {:ok, []} end)
      :meck.expect(Memory, :search_stats, fn -> nil end)
      :meck.expect(Clipboard, :copy, fn _ -> :ok end)
      :meck.expect(Notifier, :notify, fn _, _ -> :ok end)

      {_stdout, stderr} =
        capture_all(fn ->
          assert :ok == Cmd.Ask.run(%{question: "hello", edit: true}, [], [])
        end)

      assert stderr =~ "Worktree changes merged successfully"
      assert stderr =~ "abc123 add feature file"
      assert Settings.get_project_root_override() == nil

      assert_receive {:ui_say, output}
      refute output =~ "Worktree path:"
    end

    test "notes that --yes triggered auto-merge and clears the worktree summary" do
      {:ok, worktree_dir} = tmpdir()
      Settings.set_project_root_override(worktree_dir)
      parent = self()
      project = Store.Project.new("demo", "/tmp/demo")
      settings = Settings.new()

      :meck.expect(Settings, :get_project_data, fn ^settings, "demo" ->
        %{"root" => "/tmp/demo"}
      end)

      :meck.expect(Store, :get_project, fn -> {:ok, project} end)
      :meck.expect(Store.Project, :index_status, fn _ -> %{new: [], stale: [], deleted: []} end)
      :meck.expect(UI, :quiet?, fn -> true end)
      :meck.expect(UI, :debug, fn _, _ -> :ok end)
      :meck.expect(UI, :error, fn _ -> :ok end)
      :meck.expect(UI, :report_step, fn _, _ -> :ok end)
      :meck.expect(UI, :flush, fn -> :ok end)
      :meck.expect(UI, :warn, fn _ -> :ok end)
      :meck.expect(UI, :spin, fn _label, fun -> fun.() end)

      :meck.expect(UI, :say, fn message ->
        send(parent, {:ui_say, message})
        :ok
      end)

      :meck.expect(GitCli, :is_worktree?, fn -> false end)
      :meck.expect(GitCli.Worktree, :fnord_managed?, fn "demo", ^worktree_dir -> true end)
      :meck.expect(GitCli.Worktree, :has_uncommitted_changes?, fn ^worktree_dir -> true end)

      :meck.expect(GitCli.Worktree, :has_changes_to_merge?, fn "/tmp/demo",
                                                               ^worktree_dir,
                                                               "feat",
                                                               "main" ->
        true
      end)

      :meck.expect(GitCli.Worktree.Review, :auto_merge, fn "/tmp/demo", meta, _opts ->
        assert meta.path == worktree_dir
        assert meta.branch == "feat"
        assert meta.base_branch == "main"
        {:cleaned_up, {"bbb000", "def456"}, :auto}
      end)

      :meck.expect(GitCli.Worktree, :log_oneline, fn _root, "bbb000", "def456" ->
        ["def456 auto feature"]
      end)

      :meck.expect(Services.Conversation, :start_link, fn _ -> {:ok, self()} end)
      :meck.expect(Services.Conversation, :get_id, fn _ -> "conv-1" end)

      :meck.expect(Services.Conversation, :get_conversation_meta, fn _ ->
        %{worktree: %{path: worktree_dir, branch: "feat", base_branch: "main"}}
      end)

      :meck.expect(Services.Conversation, :upsert_conversation_meta, fn _, %{worktree: nil} ->
        :ok
      end)

      :meck.expect(Services.Conversation, :get_response, fn _, _ ->
        {:ok, %{usage: 1, context: 2, last_response: "hello", editing_tools_used: true}}
      end)

      :meck.expect(Services.Conversation, :save, fn _ ->
        {:ok, %{id: "conv-1", store_path: "/tmp/conv-1.json"}}
      end)

      :meck.expect(Services.Task, :start_link, fn opts ->
        assert Keyword.get(opts, :conversation_pid) == self()
        {:ok, self()}
      end)

      :meck.expect(Memory, :init, fn -> :ok end)
      :meck.expect(Memory, :list, fn _ -> {:ok, []} end)
      :meck.expect(Memory, :search_stats, fn -> nil end)
      :meck.expect(Clipboard, :copy, fn _ -> :ok end)
      :meck.expect(Notifier, :notify, fn _, _ -> :ok end)

      {_stdout, stderr} =
        capture_all(fn ->
          assert :ok == Cmd.Ask.run(%{question: "hello", edit: true, yes: true}, [], [])
        end)

      assert stderr =~ "auto-merged because --yes was specified"
      assert stderr =~ "def456 auto feature"
      assert Settings.get_project_root_override() == nil

      assert_receive {:ui_say, output}
      refute output =~ "Worktree path:"
    end
  end

  describe "commit indexer startup" do
    setup do
      :ok = safe_meck_new(Services.CommitIndexer, [:passthrough])
      :ok = safe_meck_new(GitCli, [:passthrough])
      :ok = safe_meck_new(Services.Conversation, [:passthrough])
      :ok = safe_meck_new(Services.Task, [:passthrough])
      :ok = safe_meck_new(Memory, [:passthrough])
      :ok = safe_meck_new(Clipboard, [:passthrough])
      :ok = safe_meck_new(Notifier, [:passthrough])
      :ok = safe_meck_new(UI, [:passthrough])
      :ok = safe_meck_new(Store, [:passthrough])

      :meck.expect(UI, :quiet?, fn -> true end)
      :meck.expect(UI, :error, fn _ -> :ok end)
      :meck.expect(UI, :debug, fn _, _ -> :ok end)
      :meck.expect(UI, :report_step, fn _, _ -> :ok end)
      :meck.expect(UI, :say, fn _ -> :ok end)
      :meck.expect(UI, :flush, fn -> :ok end)
      :meck.expect(UI, :warn, fn _ -> :ok end)
      :meck.expect(UI, :spin, fn _label, fun -> fun.() end)
      :meck.expect(Services.Conversation, :start_link, fn _ -> {:ok, self()} end)
      :meck.expect(Services.Conversation, :get_id, fn _ -> "conv-1" end)
      :meck.expect(Services.Conversation, :get_conversation_meta, fn _ -> %{} end)

      :meck.expect(Services.Conversation, :get_response, fn _, _ ->
        {:ok, %{usage: 1, context: 2, last_response: "hello"}}
      end)

      :meck.expect(Services.Conversation, :save, fn _ ->
        {:ok, %{id: "conv-1", store_path: "/tmp/conv-1.json"}}
      end)

      :meck.expect(Services.Task, :start_link, fn opts ->
        assert Keyword.get(opts, :conversation_pid) == self()
        {:ok, self()}
      end)

      :meck.expect(Memory, :init, fn -> :ok end)
      :meck.expect(Memory, :list, fn _ -> {:ok, []} end)
      :meck.expect(Memory, :search_stats, fn -> nil end)
      :meck.expect(Clipboard, :copy, fn _ -> :ok end)
      :meck.expect(Notifier, :notify, fn _, _ -> :ok end)
      project = mock_project("ask_commit_indexer")
      :meck.expect(Store, :get_project, fn -> {:ok, project} end)

      on_exit(fn ->
        Enum.each(
          [
            Services.CommitIndexer,
            GitCli,
            Services.Conversation,
            Services.Task,
            Memory,
            Clipboard,
            Notifier,
            UI,
            Store
          ],
          fn mod ->
            try do
              :meck.unload(mod)
            catch
              _, _ -> :ok
            end
          end
        )
      end)

      :ok
    end

    test "starts the commit indexer in git repositories" do
      parent = self()
      project = Store.get_project() |> elem(1)

      :meck.expect(GitCli, :is_git_repo?, fn -> true end)
      :meck.expect(Services.CommitIndexer, :start_link, fn -> {:ok, parent} end)

      :meck.expect(Services.CommitIndexer, :stop, fn pid ->
        assert pid == parent
        send(parent, :commit_indexer_stopped)
        :ok
      end)

      :meck.expect(Store, :get_project, fn -> {:ok, project} end)

      {_stdout, _stderr} =
        capture_all(fn ->
          assert :ok == Cmd.Ask.run(%{question: "hello"}, [], [])
        end)

      assert :meck.called(Services.CommitIndexer, :start_link, [])
    end

    test "skips the commit indexer outside git repositories" do
      :meck.expect(GitCli, :is_git_repo?, fn -> false end)
      :meck.expect(Services.CommitIndexer, :start_link, fn _opts -> flunk("should not start") end)

      {_stdout, _stderr} =
        capture_all(fn ->
          assert :ok == Cmd.Ask.run(%{question: "hello"}, [], [])
        end)

      refute :meck.called(Services.CommitIndexer, :start_link, [[]])
    end
  end
end

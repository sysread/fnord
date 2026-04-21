defmodule Services.CommitIndexerTest do
  use Fnord.TestCase, async: false

  alias Services.CommitIndexer
  alias Store.Project.CommitIndex

  setup do
    project = mock_project("commit_indexer_test")
    {:ok, project: project}
  end

  setup do
    safe_meck_new(CommitIndex, [:no_link, :passthrough, :non_strict])
    on_exit(fn -> safe_meck_unload(CommitIndex) end)

    safe_meck_new(GitCli, [:no_link, :passthrough, :non_strict])
    on_exit(fn -> safe_meck_unload(GitCli) end)

    safe_meck_new(Services.BgIndexingControl, [:no_link, :passthrough, :non_strict])
    on_exit(fn -> safe_meck_unload(Services.BgIndexingControl) end)

    # BgIndexingControl.ensure_init ensures the ETS table exists; passthrough.
    :meck.expect(Services.BgIndexingControl, :ensure_init, fn -> :ok end)
    :meck.expect(Services.BgIndexingControl, :paused?, fn _ -> false end)

    :meck.expect(GitCli, :is_git_repo_at?, fn _ -> true end)

    :ok
  end

  # Regression: index_status/1 was previously called once per cycle, which
  # re-enumerated the entire commit history (O(M) `git show` forks) for every
  # commit processed. The indexer now resolves candidates once in init/1.
  test "index_status is called exactly once per session", %{project: project} do
    test_pid = self()

    commit_a = fake_commit("aaa111", "first")
    commit_b = fake_commit("bbb222", "second")
    commit_c = fake_commit("ccc333", "third")

    :meck.expect(CommitIndex, :index_status, fn _project ->
      send(test_pid, :index_status_called)
      %{new: [commit_a, commit_b, commit_c], stale: [], deleted: []}
    end)

    :meck.expect(CommitIndex, :build_metadata, fn commit ->
      %{document: "doc-#{commit.sha}", metadata: %{"sha" => commit.sha}}
    end)

    :meck.expect(CommitIndex, :write_embeddings, fn ^project, sha, _emb, _meta ->
      send(test_pid, {:wrote, sha})
      :ok
    end)

    {:ok, pid} = CommitIndexer.start_link(project: project)
    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

    # Exactly one enumeration, not one per commit.
    assert_received :index_status_called
    refute_received :index_status_called

    assert_received {:wrote, "aaa111"}
    assert_received {:wrote, "bbb222"}
    assert_received {:wrote, "ccc333"}
  end

  # Budget the initial candidate list to @max_commits_per_session so the
  # session cannot drift from its advertised cap.
  test "candidate list is capped at @max_commits_per_session", %{project: project} do
    commits = for i <- 1..25, do: fake_commit(String.pad_leading("#{i}", 6, "0"), "c#{i}")
    test_pid = self()

    :meck.expect(CommitIndex, :index_status, fn _project ->
      %{new: commits, stale: [], deleted: []}
    end)

    :meck.expect(CommitIndex, :build_metadata, fn commit ->
      %{document: "doc-#{commit.sha}", metadata: %{"sha" => commit.sha}}
    end)

    :meck.expect(CommitIndex, :write_embeddings, fn ^project, sha, _emb, _meta ->
      send(test_pid, {:wrote, sha})
      :ok
    end)

    {:ok, pid} = CommitIndexer.start_link(project: project)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

    written =
      Stream.repeatedly(fn ->
        receive do
          {:wrote, sha} -> sha
        after
          0 -> :halt
        end
      end)
      |> Enum.take_while(&(&1 != :halt))

    assert length(written) == 10
  end

  defp fake_commit(sha, subject) do
    %{
      sha: sha,
      parent_shas: [],
      subject: subject,
      body: "",
      author: "test",
      committed_at: "1700000000",
      changed_files: [],
      diffstat: [],
      embedding_model: "stub",
      last_indexed_ts: 0
    }
  end
end

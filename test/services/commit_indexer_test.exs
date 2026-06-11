defmodule Services.CommitIndexerTest do
  # Sync: the indexer is an ad-hoc GenServer whose init/1 calls GitCli.Mock
  # before start_link returns, so per-process Mox allowances cannot be
  # granted in time - global mode (async: false) is required.
  use Fnord.TestCase, async: false

  alias Services.CommitIndexer
  alias Store.Project.CommitIndex

  setup do
    project = mock_project("commit_indexer_test")

    # Git state is scripted through the GitCli facade: the mock project dir
    # is not a repo, so enumeration (commit_shas/meta/numstat) is canned and
    # the repo checks are forced true. Everything downstream runs real:
    # index_status classification, build_metadata, embeddings via the
    # default MockIndexer stub, and write_embeddings to the tmpdir store.
    mock_git_cli()
    Mox.stub(GitCli.Mock, :is_git_repo_at?, fn _ -> true end)
    Mox.stub(GitCli.Mock, :default_branch, fn _ -> "main" end)
    Mox.stub(GitCli.Mock, :commit_numstat, fn _root, _sha -> {:ok, {[], []}} end)

    Mox.stub(GitCli.Mock, :commit_meta, fn _root, sha ->
      {:ok,
       %{
         sha: sha,
         parent_shas: [],
         author: "test",
         committed_at: "1700000000",
         subject: "subject #{sha}",
         body: ""
       }}
    end)

    {:ok, project: project}
  end

  # Regression: commit enumeration was previously re-run once per cycle,
  # which re-enumerated the entire commit history (O(M) `git show` forks)
  # for every commit processed. The indexer now resolves candidates once in
  # init/1, so the rev-list sentinel must fire exactly once per session.
  test "commit history is enumerated exactly once per session", %{project: project} do
    test_pid = self()
    shas = ["aaa111", "bbb222", "ccc333"]

    Mox.stub(GitCli.Mock, :commit_shas, fn _root, "main" ->
      send(test_pid, :enumerated)
      {:ok, shas}
    end)

    {:ok, pid} = CommitIndexer.start_link(project: project)
    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

    # Exactly one enumeration, not one per commit.
    assert_received :enumerated
    refute_received :enumerated

    # Each candidate was embedded and persisted to the real store.
    for sha <- shas do
      assert {:ok, %{metadata: metadata}} = CommitIndex.read_embeddings(project, sha)
      assert metadata["sha"] == sha
    end
  end

  # Budget the initial candidate list to @max_commits_per_session so the
  # session cannot drift from its advertised cap.
  test "candidate list is capped at @max_commits_per_session", %{project: project} do
    shas = for i <- 1..25, do: String.pad_leading("#{i}", 6, "0")

    Mox.stub(GitCli.Mock, :commit_shas, fn _root, "main" -> {:ok, shas} end)

    {:ok, pid} = CommitIndexer.start_link(project: project)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

    assert CommitIndex.all_embeddings(project) |> Enum.count() == 10
  end
end

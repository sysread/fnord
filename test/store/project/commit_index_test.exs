defmodule Store.Project.CommitIndexTest do
  use Fnord.TestCase, async: false

  alias Store.Project.CommitIndex

  setup do
    {:ok, project: mock_project("commit_index_test")}
  end

  test "root/1 and path_for/2 build expected paths", %{project: project} do
    sha = "DEADBEEF"

    expected_root = Path.join(project.store_path, "commits/index")
    assert CommitIndex.root(project) == expected_root

    expected_path = Path.join(expected_root, sha)
    assert CommitIndex.path_for(project, sha) == expected_path
  end

  test "write_embeddings/4 and read_embeddings/2 roundtrip", %{project: project} do
    sha = "roundtrip"
    embeddings = [0.1, 0.2, 0.3]

    metadata = %{
      "sha" => sha,
      "last_indexed_ts" => 1234,
      "embedding_model" => "test-model",
      "index_format_version" => 1,
      "doc_hash" => "abc123"
    }

    assert :ok = CommitIndex.write_embeddings(project, sha, embeddings, metadata)

    assert {:ok, %{embeddings: ^embeddings, metadata: ^metadata}} =
             CommitIndex.read_embeddings(project, sha)
  end

  test "all_embeddings/1 enumerates indexed commits", %{project: project} do
    sha1 = "commit-one"
    sha2 = "commit-two"

    assert :ok =
             CommitIndex.write_embeddings(project, sha1, [1.0], %{
               "sha" => sha1,
               "last_indexed_ts" => 1,
               "embedding_model" => "test-model",
               "index_format_version" => 1,
               "doc_hash" => "hash-1"
             })

    assert :ok =
             CommitIndex.write_embeddings(project, sha2, [2.0], %{
               "sha" => sha2,
               "last_indexed_ts" => 2,
               "embedding_model" => "test-model",
               "index_format_version" => 1,
               "doc_hash" => "hash-2"
             })

    all = CommitIndex.all_embeddings(project) |> Enum.into([])

    assert Enum.any?(all, fn
             {id, [1.0], metadata} ->
               id == sha1 and
                 metadata["sha"] == sha1 and
                 metadata["last_indexed_ts"] == 1 and
                 metadata["embedding_model"] == "test-model" and
                 metadata["index_format_version"] == 1 and
                 metadata["doc_hash"] == "hash-1"

             _ ->
               false
           end)

    assert Enum.any?(all, fn
             {id, [2.0], metadata} ->
               id == sha2 and
                 metadata["sha"] == sha2 and
                 metadata["last_indexed_ts"] == 2 and
                 metadata["embedding_model"] == "test-model" and
                 metadata["index_format_version"] == 1 and
                 metadata["doc_hash"] == "hash-2"

             _ ->
               false
           end)
  end

  test "delete/2 removes index directory", %{project: project} do
    sha = "todelete"

    assert :ok =
             CommitIndex.write_embeddings(project, sha, [0.5], %{
               "sha" => sha,
               "last_indexed_ts" => 10,
               "embedding_model" => "test-model",
               "index_format_version" => 1,
               "doc_hash" => "delete-me"
             })

    dir = CommitIndex.path_for(project, sha)
    assert File.dir?(dir)

    assert :ok = CommitIndex.delete(project, sha)
    refute File.exists?(dir)
  end

  test "index_status/1 reports new, stale, and deleted commits", %{project: project} do
    git_init!(project)
    git_config_user!(project)

    File.write!(Path.join(project.source_root, "tracked.txt"), "one")
    System.cmd("git", ["add", "."], cd: project.source_root)
    System.cmd("git", ["commit", "-m", "first", "--quiet"], cd: project.source_root)
    File.write!(Path.join(project.source_root, "tracked.txt"), "two")
    System.cmd("git", ["add", "."], cd: project.source_root)
    System.cmd("git", ["commit", "-m", "second", "--quiet"], cd: project.source_root)

    [new_commit | _] = CommitIndex.index_status(project).new
    new_sha = new_commit.sha
    stale_sha = "commit_stale"
    deleted_sha = "commit_deleted"

    for sha <- [stale_sha, deleted_sha] do
      dir = CommitIndex.path_for(project, sha)
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, "metadata.json"),
        SafeJson.encode!(%{
          "sha" => sha,
          "last_indexed_ts" => 100,
          "embedding_model" => "test-model",
          "index_format_version" => 1,
          "doc_hash" => "hash-#{sha}"
        })
      )

      File.write!(Path.join(dir, "embeddings.json"), SafeJson.encode!([0.0]))
    end

    status = CommitIndex.index_status(project)

    assert Enum.any?(status.new, &(&1.sha == new_sha))
    assert deleted_sha in status.deleted
  end

  test "index_status/1 treats metadata changes as stale", %{project: project} do
    git_init!(project)
    git_config_user!(project)

    File.write!(Path.join(project.source_root, "tracked.txt"), "one")
    System.cmd("git", ["add", "."], cd: project.source_root)
    System.cmd("git", ["commit", "-m", "first", "--quiet"], cd: project.source_root)

    commit = CommitIndex.index_status(project).new |> List.first()

    assert :ok =
             CommitIndex.write_embeddings(project, commit.sha, [0.0], %{
               "sha" => commit.sha,
               "last_indexed_ts" => 1,
               "embedding_model" => "test-model",
               "index_format_version" => 1,
               "doc_hash" => "doc-hash-1"
             })

    assert {:ok, %{metadata: metadata}} = CommitIndex.read_embeddings(project, commit.sha)

    for {field, value} <- [
          {"embedding_model", "other-model"},
          {"index_format_version", 2},
          {"doc_hash", "doc-hash-2"}
        ] do
      stale_metadata = Map.put(metadata, field, value)
      :ok = CommitIndex.write_embeddings(project, commit.sha, [0.0], stale_metadata)

      assert %{stale: stale} = CommitIndex.index_status(project)
      assert Enum.any?(stale, fn item -> item.sha == commit.sha end)

      :ok = CommitIndex.write_embeddings(project, commit.sha, [0.0], metadata)
    end
  end
end

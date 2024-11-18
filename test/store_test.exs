defmodule StoreTest do
  use ExUnit.Case

  setup do
    # Create a unique temporary directory
    {:ok, tmp_dir} = Briefly.create(directory: true)

    # Save the original HOME environment variable
    original_home = System.get_env("HOME")

    # Override the HOME environment variable with the temporary directory
    System.put_env("HOME", tmp_dir)

    # Ensure the original HOME is restored after tests
    on_exit(fn ->
      if original_home do
        System.put_env("HOME", original_home)
      else
        System.delete_env("HOME")
      end
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "new/1 creates a new store for the project", %{tmp_dir: tmp_dir} do
    store = Store.new("test_project")
    expected_path = Path.join([tmp_dir, ".fnord", "test_project"])
    assert store.project == "test_project"
    assert store.path == expected_path
    assert File.exists?(expected_path)
    assert File.dir?(expected_path)
  end

  test "put/5 stores file data in the store", %{tmp_dir: tmp_dir} do
    store = Store.new("test_project")

    file_path = Path.join(tmp_dir, "file.txt")
    File.write!(file_path, "Sample content")

    hash = "somehash"
    summary = "This is a summary."
    outline = "This is an outline."

    embeddings = [
      %{"embedding" => [0.1, 0.2, 0.3]},
      %{"embedding" => [0.4, 0.5, 0.6]}
    ]

    Store.put(store, file_path, hash, summary, outline, embeddings)

    key = :crypto.hash(:sha256, Path.expand(file_path)) |> Base.encode16(case: :lower)
    entry_path = Path.join(store.path, key)

    assert File.exists?(entry_path)
    assert File.dir?(entry_path)

    metadata_file = Path.join(entry_path, "metadata.json")
    assert File.exists?(metadata_file)
    {:ok, metadata} = File.read(metadata_file)
    {:ok, meta} = Jason.decode(metadata)

    assert meta["file"] == Path.expand(file_path)
    assert meta["hash"] == hash
    assert is_binary(meta["timestamp"])

    summary_file = Path.join(entry_path, "summary")
    assert File.exists?(summary_file)
    {:ok, summary_content} = File.read(summary_file)
    assert summary_content == summary

    embedding_files = Path.wildcard(Path.join(entry_path, "embedding_*.json"))
    assert length(embedding_files) == 2

    [embedding_file1, embedding_file2] = Enum.sort(embedding_files)
    {:ok, embedding_content1} = File.read(embedding_file1)
    {:ok, embedding_content2} = File.read(embedding_file2)

    assert Jason.decode!(embedding_content1) == embeddings |> Enum.at(0)
    assert Jason.decode!(embedding_content2) == embeddings |> Enum.at(1)
  end

  test "get/2 retrieves stored data", %{tmp_dir: tmp_dir} do
    store = Store.new("test_project")

    file_path = Path.join(tmp_dir, "file.txt")
    File.write!(file_path, "Sample content")

    hash = "somehash"
    summary = "This is a summary."
    outline = "This is an outline."

    embeddings = [
      %{"embedding" => [0.1, 0.2, 0.3]},
      %{"embedding" => [0.4, 0.5, 0.6]}
    ]

    Store.put(store, file_path, hash, summary, outline, embeddings)

    {:ok, info} = Store.get(store, file_path)

    assert info["file"] == Path.expand(file_path)
    assert info["hash"] == hash
    assert info["summary"] == summary
    assert info["embeddings"] == embeddings
  end

  test "get_embeddings/2 retrieves embeddings", %{tmp_dir: tmp_dir} do
    store = Store.new("test_project")

    file_path = Path.join(tmp_dir, "file.txt")
    File.write!(file_path, "Sample content")

    hash = "somehash"
    summary = "This is a summary."
    outline = "This is an outline."

    embeddings = [
      %{"embedding" => [0.1, 0.2, 0.3]},
      %{"embedding" => [0.4, 0.5, 0.6]}
    ]

    Store.put(store, file_path, hash, summary, outline, embeddings)

    {:ok, retrieved_embeddings} = Store.get_embeddings(store, file_path)
    assert retrieved_embeddings == embeddings
  end

  test "list_files/1 lists all files in the store", %{tmp_dir: tmp_dir} do
    store = Store.new("test_project")

    file_path1 = Path.join(tmp_dir, "file1.txt")
    File.write!(file_path1, "Content 1")
    file_path2 = Path.join(tmp_dir, "file2.txt")
    File.write!(file_path2, "Content 2")

    hash = "hash"
    summary = "Summary"
    outline = "Outline"
    embeddings = []

    Store.put(store, file_path1, hash, summary, outline, embeddings)
    Store.put(store, file_path2, hash, summary, outline, embeddings)

    files = Store.list_files(store)

    assert Enum.sort(files) == Enum.sort([Path.expand(file_path1), Path.expand(file_path2)])
  end

  test "list_projects/0 lists all projects", _ do
    Store.new("project1")
    Store.new("project2")

    projects = Store.list_projects()

    assert Enum.sort(projects) == Enum.sort(["project1", "project2"])
  end

  test "delete_file/2 removes file from store", %{tmp_dir: tmp_dir} do
    store = Store.new("test_project")

    file_path = Path.join(tmp_dir, "file.txt")
    File.write!(file_path, "Sample content")

    hash = "hash"
    summary = "Summary"
    outline = "Outline"
    embeddings = []

    Store.put(store, file_path, hash, summary, outline, embeddings)

    files = Store.list_files(store)
    assert files == [Path.expand(file_path)]

    Store.delete_file(store, file_path)

    files = Store.list_files(store)
    assert files == []
  end

  test "delete_project/1 removes the project directory", _ do
    store = Store.new("test_project")

    assert File.exists?(store.path)

    Store.delete_project(store)

    refute File.exists?(store.path)
  end

  test "delete_missing_files/2 deletes missing files from store", %{tmp_dir: tmp_dir} do
    store = Store.new("test_project")

    file_path1 = Path.join(tmp_dir, "file1.txt")
    File.write!(file_path1, "Content 1")
    file_path2 = Path.join(tmp_dir, "file2.txt")
    File.write!(file_path2, "Content 2")

    hash = "hash"
    summary = "Summary"
    outline = "Outline"
    embeddings = []

    Store.put(store, file_path1, hash, summary, outline, embeddings)
    Store.put(store, file_path2, hash, summary, outline, embeddings)

    File.rm!(file_path1)

    files = Store.list_files(store)
    assert Enum.sort(files) == Enum.sort([Path.expand(file_path1), Path.expand(file_path2)])

    Store.delete_missing_files(store, tmp_dir)

    files = Store.list_files(store)
    assert files == [Path.expand(file_path2)]
  end

  test "get_hash/2 retrieves hash from stored metadata", %{tmp_dir: tmp_dir} do
    store = Store.new("test_project")

    file_path = Path.join(tmp_dir, "file.txt")
    File.write!(file_path, "Sample content")

    hash = "somehash"
    summary = "Summary"
    outline = "Outline"
    embeddings = []

    Store.put(store, file_path, hash, summary, outline, embeddings)

    result = Store.get_hash(store, file_path)
    assert result == hash
  end

  test "info/2 retrieves metadata for stored file", %{tmp_dir: tmp_dir} do
    store = Store.new("test_project")

    file_path = Path.join(tmp_dir, "file.txt")
    File.write!(file_path, "Sample content")

    hash = "somehash"
    summary = "Summary"
    outline = "Outline"
    embeddings = []

    Store.put(store, file_path, hash, summary, outline, embeddings)

    {:ok, info} = Store.info(store, file_path)
    key = :crypto.hash(:sha256, Path.expand(file_path)) |> Base.encode16(case: :lower)

    assert info["file"] == Path.expand(file_path)
    assert info["hash"] == hash
    assert info["fnord_path"] == Path.join(store.path, key)
  end

  test "info/2 returns error when file is not in store", %{tmp_dir: tmp_dir} do
    store = Store.new("test_project")

    file_path = Path.join(tmp_dir, "file.txt")
    File.write!(file_path, "Sample content")

    result = Store.info(store, file_path)
    assert result == {:error, :not_found}
  end

  test "get_summary/2 retrieves summary for stored file", %{tmp_dir: tmp_dir} do
    store = Store.new("test_project")

    file_path = Path.join(tmp_dir, "file.txt")
    File.write!(file_path, "Sample content")

    hash = "somehash"
    summary = "This is a summary."
    outline = "This is an outline."
    embeddings = []

    Store.put(store, file_path, hash, summary, outline, embeddings)

    {:ok, retrieved_summary} = Store.get_summary(store, file_path)
    assert retrieved_summary == summary
  end
end

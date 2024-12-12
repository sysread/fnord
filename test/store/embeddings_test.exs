defmodule Store.EmbeddingsTest do
  use ExUnit.Case
  use TestUtil

  setup do: set_log_level(:none)

  setup do
    # Create a temporary directory for testing
    dir_path = Path.join(System.tmp_dir!(), "store_embeddings_test")
    File.rm_rf!(dir_path)
    File.mkdir_p!(dir_path)

    source_file = Path.join(dir_path, "source.txt")
    File.write!(source_file, "source content")

    %{entry_path: dir_path, source_file: source_file}
  end

  test "new/2 initializes the struct correctly", %{
    entry_path: entry_path,
    source_file: source_file
  } do
    embeddings = Store.Embeddings.new(entry_path, source_file)

    assert embeddings.store_path == Path.join(entry_path, "embeddings.json")
    assert embeddings.source_file == source_file
  end

  test "store_path/1 returns the correct path", %{
    entry_path: entry_path,
    source_file: source_file
  } do
    embeddings = Store.Embeddings.new(entry_path, source_file)

    assert Store.Embeddings.store_path(embeddings) == Path.join(entry_path, "embeddings.json")
  end

  test "exists?/1 returns true if file exists", %{entry_path: entry_path} do
    store_path = Path.join(entry_path, "embeddings.json")
    File.write!(store_path, "test data")

    embeddings = Store.Embeddings.new(entry_path, "dummy_source")

    assert Store.Embeddings.exists?(embeddings)
  end

  test "exists?/1 returns false if file does not exist", %{entry_path: entry_path} do
    embeddings = Store.Embeddings.new(entry_path, "dummy_source")

    refute Store.Embeddings.exists?(embeddings)
  end

  test "read/1 reads the file contents", %{entry_path: entry_path} do
    store_path = Path.join(entry_path, "embeddings.json")
    File.write!(store_path, Jason.encode!(%{"test" => "data"}))

    embeddings = Store.Embeddings.new(entry_path, "dummy_source")

    assert Store.Embeddings.read(embeddings) == {:ok, %{"test" => "data"}}
  end

  test "read/1 returns error if file does not exist", %{entry_path: entry_path} do
    embeddings = Store.Embeddings.new(entry_path, "dummy_source")

    assert {:error, _reason} = Store.Embeddings.read(embeddings)
  end

  test "write/2 writes embeddings data to file and removes old-style files", %{
    entry_path: entry_path
  } do
    old_style_file = Path.join(entry_path, "embeddings_1.json")
    File.write!(old_style_file, Jason.encode!(%{"old" => "data"}))

    embeddings = Store.Embeddings.new(entry_path, "dummy_source")
    data = [[5, 10], [3, 15]]

    assert :ok == Store.Embeddings.write(embeddings, data)

    assert File.exists?(Store.Embeddings.store_path(embeddings))
    assert Jason.decode!(File.read!(Store.Embeddings.store_path(embeddings))) == [5, 15]
    refute File.exists?(old_style_file)
  end

  test "new/2 upgrades old-style embeddings", %{entry_path: entry_path} do
    old_style_file = Path.join(entry_path, "embedding_1.json")
    File.write!(old_style_file, Jason.encode!([1, 2, 3]))

    embeddings = Store.Embeddings.new(entry_path, "dummy_source")

    assert File.exists?(Store.Embeddings.store_path(embeddings))
    assert Jason.decode!(File.read!(Store.Embeddings.store_path(embeddings))) == [1, 2, 3]
    refute File.exists?(old_style_file)
  end
end

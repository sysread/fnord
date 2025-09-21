defmodule Store.Project.Entry.MetadataTest do
  use Fnord.TestCase, async: false

  setup do
    # Create a temporary directory for testing
    dir_path = Path.join(System.tmp_dir!(), "store_metadata_test")
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
    metadata = Store.Project.Entry.Metadata.new(entry_path, source_file)

    assert metadata.store_path == Path.join(entry_path, "metadata.json")
    assert metadata.source_file == source_file
  end

  test "store_path/1 returns the correct path", %{
    entry_path: entry_path,
    source_file: source_file
  } do
    metadata = Store.Project.Entry.Metadata.new(entry_path, source_file)

    assert Store.Project.Entry.Metadata.store_path(metadata) ==
             Path.join(entry_path, "metadata.json")
  end

  test "exists?/1 returns true if file exists", %{entry_path: entry_path} do
    store_path = Path.join(entry_path, "metadata.json")
    File.write!(store_path, "test data")

    metadata = Store.Project.Entry.Metadata.new(entry_path, "dummy_source")

    assert Store.Project.Entry.Metadata.exists?(metadata)
  end

  test "exists?/1 returns false if file does not exist", %{entry_path: entry_path} do
    metadata = Store.Project.Entry.Metadata.new(entry_path, "dummy_source")

    refute Store.Project.Entry.Metadata.exists?(metadata)
  end

  test "read/1 reads the file contents", %{entry_path: entry_path} do
    store_path = Path.join(entry_path, "metadata.json")
    File.write!(store_path, Jason.encode!(%{"test" => "data"}))

    metadata = Store.Project.Entry.Metadata.new(entry_path, "dummy_source")

    assert Store.Project.Entry.Metadata.read(metadata) == {:ok, %{"test" => "data"}}
  end

  test "read/1 returns error if file does not exist", %{entry_path: entry_path} do
    metadata = Store.Project.Entry.Metadata.new(entry_path, "dummy_source")

    assert {:error, _reason} = Store.Project.Entry.Metadata.read(metadata)
  end

  test "write/2 writes metadata to file including hash and timestamp", %{
    entry_path: entry_path,
    source_file: source_file
  } do
    metadata = Store.Project.Entry.Metadata.new(entry_path, source_file)

    assert :ok == Store.Project.Entry.Metadata.write(metadata, nil)

    assert File.exists?(Store.Project.Entry.Metadata.store_path(metadata))

    {:ok, contents} = Store.Project.Entry.Metadata.read(metadata)
    assert contents["file"] == source_file

    assert contents["hash"] ==
             :crypto.hash(:sha256, File.read!(source_file)) |> Base.encode16(case: :lower)

    assert contents["timestamp"]
  end
end

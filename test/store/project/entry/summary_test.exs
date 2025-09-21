defmodule Store.Project.Entry.SummaryTest do
  use Fnord.TestCase, async: false

  setup do
    dir_path = Path.join(System.tmp_dir!(), "store_summary_test")
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
    summary = Store.Project.Entry.Summary.new(entry_path, source_file)

    assert summary.store_path == Path.join(entry_path, "summary")
    assert summary.source_file == source_file
  end

  test "store_path/1 returns the correct path", %{
    entry_path: entry_path,
    source_file: source_file
  } do
    summary = Store.Project.Entry.Summary.new(entry_path, source_file)

    assert Store.Project.Entry.Summary.store_path(summary) == Path.join(entry_path, "summary")
  end

  test "exists?/1 returns true if file exists", %{entry_path: entry_path} do
    store_path = Path.join(entry_path, "summary")
    File.write!(store_path, "test data")

    summary = Store.Project.Entry.Summary.new(entry_path, "dummy_source")

    assert Store.Project.Entry.Summary.exists?(summary)
  end

  test "exists?/1 returns false if file does not exist", %{entry_path: entry_path} do
    store_path = Path.join(entry_path, "summary")
    File.rm(store_path)

    summary = Store.Project.Entry.Summary.new(entry_path, "dummy_source")

    refute Store.Project.Entry.Summary.exists?(summary)
  end

  test "read/1 reads the file contents", %{entry_path: entry_path} do
    store_path = Path.join(entry_path, "summary")
    File.write!(store_path, "test data")

    summary = Store.Project.Entry.Summary.new(entry_path, "dummy_source")

    assert Store.Project.Entry.Summary.read(summary) == {:ok, "test data"}
  end

  test "read/1 returns error if file does not exist", %{entry_path: entry_path} do
    summary = Store.Project.Entry.Summary.new(entry_path, "dummy_source")

    assert {:error, _reason} = Store.Project.Entry.Summary.read(summary)
  end

  test "write/2 writes binary data to file", %{entry_path: entry_path} do
    summary = Store.Project.Entry.Summary.new(entry_path, "dummy_source")
    assert :ok == Store.Project.Entry.Summary.write(summary, "new data")

    assert File.read!(Store.Project.Entry.Summary.store_path(summary)) == "new data"
  end

  test "write/2 returns error if data is not binary", %{entry_path: entry_path} do
    summary = Store.Project.Entry.Summary.new(entry_path, "dummy_source")

    assert {:error, :unsupported} == Store.Project.Entry.Summary.write(summary, 12345)
  end
end

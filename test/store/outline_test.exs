defmodule Store.OutlineTest do
  use ExUnit.Case

  setup do
    dir_path = Path.join(System.tmp_dir!(), "store_outline_test")
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
    outline = Store.Outline.new(entry_path, source_file)

    assert outline.store_path == Path.join(entry_path, "outline")
    assert outline.source_file == source_file
  end

  test "store_path/1 returns the correct path", %{
    entry_path: entry_path,
    source_file: source_file
  } do
    outline = Store.Outline.new(entry_path, source_file)

    assert Store.Outline.store_path(outline) == Path.join(entry_path, "outline")
  end

  test "exists?/1 returns true if file exists", %{entry_path: entry_path} do
    store_path = Path.join(entry_path, "outline")
    File.write!(store_path, "test data")

    outline = Store.Outline.new(entry_path, "dummy_source")

    assert Store.Outline.exists?(outline)
  end

  test "exists?/1 returns false if file does not exist", %{entry_path: entry_path} do
    store_path = Path.join(entry_path, "outline")
    File.rm(store_path)

    outline = Store.Outline.new(entry_path, "dummy_source")

    refute Store.Outline.exists?(outline)
  end

  test "read/1 reads the file contents", %{entry_path: entry_path} do
    store_path = Path.join(entry_path, "outline")
    File.write!(store_path, "test data")

    outline = Store.Outline.new(entry_path, "dummy_source")

    assert Store.Outline.read(outline) == {:ok, "test data"}
  end

  test "read/1 returns error if file does not exist", %{entry_path: entry_path} do
    outline = Store.Outline.new(entry_path, "dummy_source")

    assert {:error, _reason} = Store.Outline.read(outline)
  end

  test "write/2 writes binary data to file", %{entry_path: entry_path} do
    outline = Store.Outline.new(entry_path, "dummy_source")
    assert :ok == Store.Outline.write(outline, "new data")

    assert File.read!(Store.Outline.store_path(outline)) == "new data"
  end

  test "write/2 returns error if data is not binary", %{entry_path: entry_path} do
    outline = Store.Outline.new(entry_path, "dummy_source")

    assert {:error, :unsupported} == Store.Outline.write(outline, 12345)
  end
end

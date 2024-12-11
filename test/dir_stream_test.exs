defmodule DirStreamTest do
  use ExUnit.Case

  setup do
    # Create a temporary directory structure for testing
    root_dir = Briefly.create!(directory: true)

    File.write!(Path.join(root_dir, "file1.txt"), "content")
    File.write!(Path.join(root_dir, "file2.txt"), "content")

    subdir = Path.join(root_dir, "subdir")
    File.mkdir!(subdir)
    File.write!(Path.join(subdir, "file3.txt"), "content")

    nested_subdir = Path.join(subdir, "nested_subdir")
    File.mkdir!(nested_subdir)
    File.write!(Path.join(nested_subdir, "file4.txt"), "content")

    {:ok, root_dir: root_dir}
  end

  test "stream traverses all files recursively", %{root_dir: root_dir} do
    files =
      root_dir
      |> DirStream.new()
      |> Enum.sort()

    expected_files =
      ["file1.txt", "file2.txt", "subdir/file3.txt", "subdir/nested_subdir/file4.txt"]
      |> Enum.map(&Path.expand(&1, root_dir))
      |> Enum.sort()

    assert files == expected_files
  end

  test "stream skips directories based on continue? callback", %{root_dir: root_dir} do
    skip_subdir = fn path -> not String.ends_with?(path, "subdir") end

    files =
      root_dir
      |> DirStream.new(skip_subdir)
      |> Enum.sort()

    expected_files =
      ["file1.txt", "file2.txt"]
      |> Enum.map(&Path.expand(&1, root_dir))
      |> Enum.sort()

    assert files == expected_files
  end

  test "stream handles unreadable directories gracefully", %{root_dir: root_dir} do
    unreadable_dir = Path.join(root_dir, "unreadable_dir")
    File.mkdir!(unreadable_dir)
    File.chmod!(unreadable_dir, 0o000)

    on_exit(fn -> File.chmod!(unreadable_dir, 0o755) end)

    files =
      root_dir
      |> DirStream.new()
      |> Enum.sort()

    expected_files =
      ["file1.txt", "file2.txt", "subdir/file3.txt", "subdir/nested_subdir/file4.txt"]
      |> Enum.map(&Path.expand(&1, root_dir))
      |> Enum.sort()

    assert files == expected_files
  end

  test "empty directory yields no files", _context do
    empty_dir = Briefly.create!(directory: true)

    files =
      empty_dir
      |> DirStream.new()
      |> Enum.to_list()

    assert files == []
  end
end

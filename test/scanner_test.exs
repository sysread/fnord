defmodule ScannerTest do
  use ExUnit.Case

  alias Scanner

  setup do
    # Create a temporary directory for testing
    {:ok, test_dir} = Briefly.create(directory: true)

    # Initialize a git repository in the test directory
    System.cmd("git", ["init"],
      cd: test_dir,
      env: [
        {"GIT_TRACE", "0"},
        {"GIT_CURL_VERBOSE", "0"},
        {"GIT_DEBUG", "0"}
      ]
    )

    # Create files and directories for testing
    create_test_files(test_dir)

    {:ok, test_dir: test_dir}
  end

  test "Scanner.count_files/1 counts only valid files", %{test_dir: test_dir} do
    # Initialize the scanner
    scanner = Scanner.new(test_dir, fn _ -> :ok end)

    # Count the files
    count = Scanner.count_files(scanner)

    # Expected count of valid files
    expected_count = 2

    # Assert that the count matches the expected count
    assert count == expected_count
  end

  test "Scanner.scan/1 processes only valid files", %{test_dir: test_dir} do
    # Use a process dictionary to collect processed files
    Process.put(:processed_files, [])

    # Callback function to collect processed files
    callback = fn file ->
      Process.put(:processed_files, [file | Process.get(:processed_files, [])])
    end

    # Initialize and run the scanner
    scanner = Scanner.new(test_dir, callback)
    Scanner.scan(scanner)

    # Retrieve the list of processed files
    processed_files = Process.get(:processed_files, [])

    # Expected files that should be processed
    expected_files = [
      Path.join(test_dir, "regular_file.txt"),
      Path.join(test_dir, "subdir/nested_file.txt")
    ]

    # Assert that only the expected files were processed
    assert Enum.sort(processed_files) == Enum.sort(expected_files)

    # Files that should have been skipped
    skipped_files = [
      Path.join(test_dir, "empty_file.txt"),
      Path.join(test_dir, ".hidden_file"),
      Path.join(test_dir, "binary_file.bin"),
      Path.join(test_dir, "ignored_file.txt")
    ]

    # Assert that skipped files were not processed
    Enum.each(skipped_files, fn file ->
      refute file in processed_files
    end)
  end

  defp create_test_files(test_dir) do
    # Create a regular file
    File.write!(Path.join(test_dir, "regular_file.txt"), "This is a regular file.")

    # Create an empty file
    File.write!(Path.join(test_dir, "empty_file.txt"), "")

    # Create a hidden file
    File.write!(Path.join(test_dir, ".hidden_file"), "This is a hidden file.")

    # Create a binary file containing null bytes
    File.write!(Path.join(test_dir, "binary_file.bin"), <<0, 1, 2, 3, 0>>)

    # Create a subdirectory with a nested file
    sub_dir = Path.join(test_dir, "subdir")
    File.mkdir_p!(sub_dir)
    File.write!(Path.join(sub_dir, "nested_file.txt"), "This is a nested file.")

    # Create a file that should be ignored by .gitignore
    File.write!(Path.join(test_dir, "ignored_file.txt"), "This file should be ignored.")

    # Create a .gitignore file
    File.write!(Path.join(test_dir, ".gitignore"), "ignored_file.txt\n")
  end
end

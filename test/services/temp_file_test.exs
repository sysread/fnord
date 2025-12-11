defmodule Services.TempFileTest do
  use Fnord.TestCase, async: false

  @moduledoc false

  test "mktemp/1 delegates to Briefly and returns a path" do
    # We do not want to mock Briefly here; just ensure that the call works and
    # returns an existing file.
    assert {:ok, path} = Services.TempFile.mktemp(prefix: "tempfile-test-", extname: ".log")
    assert is_binary(path)
    assert String.contains?(path, "tempfile-test-")

    # File should exist at least for the duration of this test.
    assert File.exists?(path)
  end

  test "mktemp!/1 returns a path on success" do
    assert path = Services.TempFile.mktemp!(prefix: "tempfile-test-", extname: ".log")
    assert is_binary(path)
    assert String.contains?(path, "tempfile-test-")
    assert File.exists?(path)
  end
end

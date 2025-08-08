defmodule HunkTest do
  use Fnord.TestCase

  setup do
    proj = mock_project("hunk_test")

    path =
      mock_source_file(
        proj,
        "sample.txt",
        """
        line1
        line2
        line3
        line4
        line5
        """
      )

    {:ok, %{project: proj, path: path}}
  end

  describe "find_contents/3" do
    test "returns the requested lines, inclusive", %{path: path} do
      assert {:ok, contents} = Hunk.find_contents(path, 2, 4)
      assert contents == "line2\nline3\nline4"
    end

    test "rejects start_line < 1", %{path: path} do
      assert {:error, :invalid_start_line} = Hunk.find_contents(path, 0, 3)
    end

    test "rejects end_line < start_line", %{path: path} do
      assert {:error, :invalid_end_line} = Hunk.find_contents(path, 4, 3)
    end

    test "rejects end_line past EOF", %{path: path} do
      assert {:error, :end_line_exceeds_file_length} = Hunk.find_contents(path, 3, 99)
    end

    test "returns :file_not_found for missing file", %{project: proj} do
      missing = Path.join(proj.source_root, "missing.txt")
      assert {:error, :file_not_found} = Hunk.find_contents(missing, 1, 1)
    end
  end

  describe "new/3" do
    test "builds a Hunk with correct contents and md5", %{path: path} do
      assert {:ok, h} = Hunk.new(path, 2, 4)
      assert %Hunk{} = h
      assert h.file == path
      assert h.start_line == 2
      assert h.end_line == 4
      assert h.contents == "line2\nline3\nline4"

      expected_hash =
        :crypto.hash(:md5, File.read!(path)) |> Base.encode16(case: :lower)

      assert h.hash == expected_hash
    end

    test "bubbles up errors from md5/find_contents", %{project: proj, path: path} do
      # missing file
      missing = Path.join(proj.source_root, "nope.txt")
      assert {:error, :file_not_found} = Hunk.new(missing, 1, 1)

      # invalid ranges
      assert {:error, :invalid_start_line} = Hunk.new(path, 0, 1)
      assert {:error, :invalid_end_line} = Hunk.new(path, 3, 2)
      assert {:error, :end_line_exceeds_file_length} = Hunk.new(path, 4, 99)
    end
  end

  describe "with_context/4" do
    test "returns snippet with anchors and surrounding context", %{project: proj} do
      file =
        mock_source_file(
          proj,
          "context.txt",
          """
          a1
          a2
          a3
          a4
          a5
          """
        )

      {:ok, hunk} = Hunk.new(file, 3, 3)
      assert {:ok, snippet} = Hunk.with_context(hunk, "[[", "]]", 1)

      assert snippet == """
             a2
             [[
             a3
             ]]
             a4
             """
    end

    test "returns :not_found when hunk.contents is not in file", %{project: proj} do
      file =
        mock_source_file(
          proj,
          "not_found.txt",
          """
          x1
          x2
          x3
          """
        )

      {:ok, hunk} = Hunk.new(file, 1, 1)

      File.write!(file, "a\nb\nc\n")

      assert {:error, :not_found} = Hunk.with_context(hunk, "<", ">", 2)
    end
  end

  describe "is_stale?/1" do
    test "returns false when file hash matches hunk hash", %{path: path} do
      hash = :crypto.hash(:md5, File.read!(path)) |> Base.encode16(case: :lower)

      hunk = %Hunk{
        file: path,
        start_line: 1,
        end_line: 1,
        contents: "line1",
        hash: hash
      }

      refute Hunk.is_stale?(hunk)
    end

    test "returns true when file hash differs from hunk hash", %{path: path} do
      hunk = %Hunk{
        file: path,
        start_line: 1,
        end_line: 1,
        contents: "line1",
        hash: "differenthash"
      }

      assert Hunk.is_stale?(hunk)
    end

    test "returns true when file cannot be read" do
      hunk = %Hunk{
        file: "/path/does/not/exist",
        start_line: 1,
        end_line: 1,
        contents: "line1",
        hash: "ignored"
      }

      assert Hunk.is_stale?(hunk)
    end
  end

  describe "is_valid?/1" do
    test "returns true when file is not stale", %{path: path} do
      hash = :crypto.hash(:md5, File.read!(path)) |> Base.encode16(case: :lower)

      hunk = %Hunk{
        file: path,
        start_line: 2,
        end_line: 3,
        contents: "line2\nline3",
        hash: hash
      }

      assert Hunk.is_valid?(hunk)
    end

    test "returns true when file is stale but contents at range are unchanged", %{path: path} do
      hunk = %Hunk{
        file: path,
        start_line: 2,
        end_line: 3,
        contents: "line2\nline3",
        hash: "wronghash"
      }

      assert Hunk.is_valid?(hunk)
    end

    test "returns false when file is stale and contents at range have changed", %{project: proj} do
      path =
        mock_source_file(
          proj,
          "changed.txt",
          """
          aaa
          bbb
          ccc
          """
        )

      hunk = %Hunk{
        file: path,
        start_line: 2,
        end_line: 3,
        contents: "old\ncontents",
        hash: "wronghash"
      }

      refute Hunk.is_valid?(hunk)
    end

    test "returns false when file cannot be read" do
      hunk = %Hunk{
        file: "/missing/file",
        start_line: 1,
        end_line: 1,
        contents: "line1",
        hash: "wronghash"
      }

      refute Hunk.is_valid?(hunk)
    end
  end

  describe "replace_in_file/2" do
    test "replaces contents in the given range when hunk is valid and up to date", %{path: path} do
      assert {:ok, hunk} = Hunk.new(path, 2, 4)

      :ok = Hunk.replace_in_file(hunk, "X\nY\nZ")

      new_contents = File.read!(path)
      assert new_contents == "line1\nX\nY\nZ\nline5\n"
    end

    test "returns {:error, :hunk_is_stale} when file hash differs", %{path: path} do
      hunk = %Hunk{
        file: path,
        start_line: 2,
        end_line: 4,
        contents: "line2\nline3\nline4",
        hash: "stalehash"
      }

      assert {:error, :hunk_is_stale} = Hunk.replace_in_file(hunk, "X")
    end

    test "returns {:error, :invalid_hunk_contents} when file contents at range differ", %{
      project: proj
    } do
      path =
        mock_source_file(
          proj,
          "bad.txt",
          """
          a
          b
          c
          """
        )

      # Create a hunk that expects lines 2-3 to be "b\nc"
      {:ok, hunk} = Hunk.new(path, 2, 3)

      # Modify the file contents so the hunk is no longer valid
      File.write!(path, "a\nX\nY\nZ\n")

      assert {:error, :invalid_hunk_contents} = Hunk.replace_in_file(hunk, "new")
    end

    test "returns {:error, :file_not_found} when file is missing", %{project: proj} do
      path = mock_source_file(proj, "missing.txt", "a\nb\nc\n")

      # Create a hunk for the file
      {:ok, hunk} = Hunk.new(path, 1, 1)

      # Then delete the file
      File.rm!(path)

      assert {:error, :file_not_found} = Hunk.replace_in_file(hunk, "data")
    end
  end
end

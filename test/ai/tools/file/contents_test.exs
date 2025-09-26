defmodule AI.Tools.File.ContentsTest do
  use Fnord.TestCase

  describe "metadata" do
    test "async?/0 returns true" do
      assert AI.Tools.File.Contents.async?() == true
    end

    test "is_available?/0 returns true" do
      assert AI.Tools.File.Contents.is_available?() == true
    end

    test "read_args/1 returns {:ok, args}" do
      args = %{"file" => "path"}
      assert AI.Tools.File.Contents.read_args(args) == {:ok, args}
    end

    test "spec/0 returns function spec with required file" do
      spec = AI.Tools.File.Contents.spec()
      assert is_map(spec)
      assert spec.type == "function"
      assert spec.function.name == "file_contents_tool"
      params = spec.function.parameters
      assert params.required == ["file"]
    end
  end

  describe "ui_note_on_request/1" do
    test "with line_numbers true returns Read +ln and ref" do
      args = %{"file" => "f.txt", "line_numbers" => true}
      assert AI.Tools.File.Contents.ui_note_on_request(args) == {"Read +ln", "f.txt (full)"}
    end

    test "with line_numbers false returns Read -ln and ref" do
      args = %{"file" => "f.txt", "line_numbers" => false}
      assert AI.Tools.File.Contents.ui_note_on_request(args) == {"Read -ln", "f.txt (full)"}
    end

    test "without line_numbers key defaults to false" do
      args = %{"file" => "f.txt"}
      assert AI.Tools.File.Contents.ui_note_on_request(args) == {"Read -ln", "f.txt (full)"}
    end

    test "with custom start and end in ref" do
      args = %{"file" => "f.txt", "start_line" => 3, "end_line" => 5}
      assert {_note, ref} = AI.Tools.File.Contents.ui_note_on_request(args)
      assert ref == "f.txt:3...5"
    end
  end

  describe "ui_note_on_result/2" do
    test "always returns nil" do
      assert AI.Tools.File.Contents.ui_note_on_result(%{}, {:ok, "x"}) == nil
    end
  end

  describe "call/1 – successful read with numbering" do
    setup do
      :meck.new(AI.Tools)
      :meck.expect(AI.Tools, :get_file_contents, fn "file.txt" -> {:ok, "one\ntwo\nthree"} end)
      :meck.new(Services.BackupFile)
      :meck.expect(Services.BackupFile, :describe_backup, fn _ -> nil end)

      on_exit(fn ->
        try do
          :meck.unload(AI.Tools)
        catch
          _, _ -> :ok
        end

        try do
          :meck.unload(Services.BackupFile)
        catch
          _, _ -> :ok
        end
      end)

      :ok
    end

    test "returns numbered lines wrapped in code fence" do
      {:ok, out} = AI.Tools.File.Contents.call(%{"file" => "file.txt"})
      assert out =~ "[file_contents_tool] Contents of file.txt:"
      assert out =~ "1\tone"
      assert out =~ "2\ttwo"
      assert out =~ "3\tthree"
      assert String.contains?(out, "```")
    end
  end

  describe "call/1 – no numbering with slice" do
    setup do
      :meck.new(AI.Tools)
      :meck.expect(AI.Tools, :get_file_contents, fn "file.txt" -> {:ok, "a\nb\nc\nd"} end)
      :meck.new(Services.BackupFile)
      :meck.expect(Services.BackupFile, :describe_backup, fn _ -> nil end)

      on_exit(fn ->
        try do
          :meck.unload(AI.Tools)
        catch
          _, _ -> :ok
        end

        try do
          :meck.unload(Services.BackupFile)
        catch
          _, _ -> :ok
        end
      end)

      :ok
    end

    test "slice lines 2 to 3 without numbering" do
      {:ok, out} =
        AI.Tools.File.Contents.call(%{
          "file" => "file.txt",
          "line_numbers" => false,
          "start_line" => 2,
          "end_line" => 3
        })

      refute String.match?(out, ~r/^1\t/)
      assert out =~ "b\nc"
    end
  end

  describe "call/1 – default no numbering" do
    setup do
      :meck.new(AI.Tools)
      :meck.expect(AI.Tools, :get_file_contents, fn "plain" -> {:ok, "x\ny"} end)
      :meck.new(Services.BackupFile)
      :meck.expect(Services.BackupFile, :describe_backup, fn _ -> nil end)

      on_exit(fn ->
        try do
          :meck.unload(AI.Tools)
        catch
          _, _ -> :ok
        end

        try do
          :meck.unload(Services.BackupFile)
        catch
          _, _ -> :ok
        end
      end)

      :ok
    end

    test "no numbering by explicit false" do
      {:ok, out} = AI.Tools.File.Contents.call(%{"file" => "plain", "line_numbers" => false})
      refute String.match?(out, ~r/^\d+\t/)
      assert out =~ "x\ny"
    end
  end

  describe "call/1 – slicing to end without end_line" do
    setup do
      :meck.new(AI.Tools)
      :meck.expect(AI.Tools, :get_file_contents, fn "toend" -> {:ok, "a\nb\nc"} end)
      :meck.new(Services.BackupFile)
      :meck.expect(Services.BackupFile, :describe_backup, fn _ -> nil end)

      on_exit(fn ->
        try do
          :meck.unload(AI.Tools)
        catch
          _, _ -> :ok
        end

        try do
          :meck.unload(Services.BackupFile)
        catch
          _, _ -> :ok
        end
      end)

      :ok
    end

    test "slice from line 2 to end" do
      {:ok, out} = AI.Tools.File.Contents.call(%{"file" => "toend", "start_line" => 2})
      assert out =~ "2\tb"
      assert out =~ "3\tc"
    end
  end

  describe "call/1 – start > end returns full content" do
    setup do
      :meck.new(AI.Tools)
      :meck.expect(AI.Tools, :get_file_contents, fn "rng" -> {:ok, "a\nb\nc"} end)
      :meck.new(Services.BackupFile)
      :meck.expect(Services.BackupFile, :describe_backup, fn _ -> nil end)

      on_exit(fn ->
        try do
          :meck.unload(AI.Tools)
        catch
          _, _ -> :ok
        end

        try do
          :meck.unload(Services.BackupFile)
        catch
          _, _ -> :ok
        end
      end)

      :ok
    end

    test "start_line > end_line returns all lines numbered" do
      {:ok, out} =
        AI.Tools.File.Contents.call(%{"file" => "rng", "start_line" => 5, "end_line" => 2})

      assert out =~ "1\ta"
      assert out =~ "3\tc"
    end
  end

  describe "call/1 – includes backup description" do
    setup do
      :meck.new(AI.Tools)
      :meck.expect(AI.Tools, :get_file_contents, fn "b.txt" -> {:ok, "ln1"} end)
      :meck.new(Services.BackupFile)
      :meck.expect(Services.BackupFile, :describe_backup, fn "b.txt" -> "bak" end)

      on_exit(fn ->
        try do
          :meck.unload(AI.Tools)
        catch
          _, _ -> :ok
        end

        try do
          :meck.unload(Services.BackupFile)
        catch
          _, _ -> :ok
        end
      end)

      :ok
    end

    test "backup note is included" do
      {:ok, out} = AI.Tools.File.Contents.call(%{"file" => "b.txt"})
      assert out =~ "bak"
    end
  end

  describe "call/1 – file not found" do
    setup do
      :meck.new(AI.Tools)
      :meck.expect(AI.Tools, :get_file_contents, fn "nof" -> {:error, :enoent} end)

      on_exit(fn ->
        try do
          :meck.unload(AI.Tools)
        catch
          _, _ -> :ok
        end
      end)

      :ok
    end

    test "returns friendly error message" do
      {:error, msg} = AI.Tools.File.Contents.call(%{"file" => "nof"})
      assert msg =~ "does not exist"
      assert msg =~ "nof"
    end
  end

  describe "call/1 – other errors" do
    setup do
      :meck.new(AI.Tools)
      :meck.expect(AI.Tools, :get_file_contents, fn "err" -> {:error, :eacces} end)

      on_exit(fn ->
        try do
          :meck.unload(AI.Tools)
        catch
          _, _ -> :ok
        end
      end)

      :ok
    end

    test "propagates non-enoent errors" do
      assert AI.Tools.File.Contents.call(%{"file" => "err"}) == {:error, :eacces}
    end
  end
end

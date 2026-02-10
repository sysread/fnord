defmodule AI.Tools.File.InfoTest do
  use Fnord.TestCase, async: false
  @moduletag capture_log: true

  setup do
    # Prepare fresh mocks for each test
    for mod <- [AI.Tools, AI.Agent, Services.BackupFile] do
      :meck.new(mod, [:passthrough])
    end

    on_exit(fn ->
      # Unload mocks after each test
      for mod <- [AI.Tools, AI.Agent, Services.BackupFile] do
        try do
          :meck.unload(mod)
        rescue
          _ -> :ok
        end
      end
    end)

    :ok
  end

  test "metadata callbacks" do
    # async?/0 and is_available?/0
    assert AI.Tools.File.Info.async?()
    assert AI.Tools.File.Info.is_available?()

    # read_args/1 validates args: missing fields produce error
    assert {:error, :missing_argument, "question"} =
             AI.Tools.File.Info.read_args(%{"foo" => "bar"})

    assert {:ok, %{"question" => "Q", "files" => ["a.ex"]}} =
             AI.Tools.File.Info.read_args(%{"question" => "Q", "files" => ["a.ex"]})

    # spec/0 shape
    spec = AI.Tools.File.Info.spec()
    assert spec.type == "function"
    assert spec.function.name == "file_info_tool"
    assert spec.function.parameters.required == ["question", "files"]
  end

  test "ui_note_on_request and ui_note_on_result format descriptions" do
    req =
      AI.Tools.File.Info.ui_note_on_request(%{"files" => ["a.ex", "b.ex"], "question" => "Q?"})

    assert req == {"Considering a.ex, b.ex", "Q?"}

    {title, body} =
      AI.Tools.File.Info.ui_note_on_result(
        %{"files" => ["file.ex"], "question" => "Why?"},
        "RESULT"
      )

    assert title == "Finished considerable considerations"
    assert body =~ "# Files"
    assert body =~ "file.ex"
    assert body =~ "# Question"
    assert body =~ "Why?"
    assert body =~ "# Result(s)"
    assert body =~ "RESULT"
  end

  describe "call/1 behavior" do
    test "success path without backup" do
      # Stub file reading and agent
      :meck.expect(AI.Tools, :get_file_contents, fn _ -> {:ok, "line1\nline2"} end)
      :meck.expect(AI.Agent, :new, fn AI.Agent.FileInfo -> :agent end)

      :meck.expect(AI.Agent, :get_response, fn :agent, opts ->
        {:ok, "RESP for #{opts.file}"}
      end)

      :meck.expect(Services.BackupFile, :describe_backup, fn _ -> nil end)

      {:ok, output} = AI.Tools.File.Info.call(%{"files" => ["f1.ex"], "question" => "Q"})
      assert output =~ "Line numbers are included"
      assert output =~ "## File\nf1.ex"
      assert output =~ "## Result\nRESP for f1.ex"
    end

    test "success path with backup and multiple files ordering" do
      # Stub file contents
      :meck.expect(AI.Tools, :get_file_contents, fn
        "x.ex" -> {:ok, "a"}
        "y.ex" -> {:ok, "b"}
      end)

      # Stub agent
      :meck.expect(AI.Agent, :new, fn AI.Agent.FileInfo -> :agent end)

      :meck.expect(AI.Agent, :get_response, fn :agent, opts ->
        {:ok, "ANS for #{opts.file}"}
      end)

      # Backup for x.ex only
      :meck.expect(Services.BackupFile, :describe_backup, fn
        "x.ex" -> "BACKUP NOTE"
        _ -> nil
      end)

      {:ok, output} = AI.Tools.File.Info.call(%{"files" => ["x.ex", "y.ex"], "question" => "Q"})
      [block1, block2] = String.split(output, "\n\n-----\n\n")

      # x.ex block
      assert block1 =~ "## File\nx.ex"
      assert block1 =~ "## Result"
      assert block1 =~ "BACKUP NOTE"
      assert block1 =~ "ANS for x.ex"

      # y.ex block
      assert block2 =~ "## File\ny.ex"
      assert block2 =~ "## Result"
      assert block2 =~ "ANS for y.ex"
      refute block2 =~ "BACKUP"
    end

    test "error path when file read fails" do
      # Simulate get_file_contents error
      :meck.expect(AI.Tools, :get_file_contents, fn _ -> {:error, :enoent} end)
      :meck.expect(Services.BackupFile, :describe_backup, fn _ -> nil end)

      {:ok, output} = AI.Tools.File.Info.call(%{"files" => ["bad.ex"], "question" => "Q"})
      assert output =~ "Unable to read the file contents"
      assert output =~ "FILE:  bad.ex"
      assert output =~ "ERROR: :enoent"
    end
  end
end

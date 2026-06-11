defmodule AI.Tools.File.InfoTest do
  use Fnord.TestCase, async: true
  @moduletag capture_log: true

  # ---------------------------------------------------------------------------
  # File contents are read for real from the project source root; the FileInfo
  # sub-agent is the only canned collaborator, scripted per test at the
  # agent-dispatch seam via canned_agent/1. Backup annotations come from the
  # real Services.BackupFile, driven by the backup-file naming convention.
  # ---------------------------------------------------------------------------

  setup do
    project = mock_project("info_test")

    # The canonical accessor resolves the project via AI.Tools.get_project/0,
    # which rejects projects whose store directory is missing or empty.
    File.mkdir_p!(Store.Project.files_root(project))

    {:ok, project: project}
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
    assert spec.name == "file_info_tool"
    assert spec.parameters.required == ["question", "files"]
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
    test "success path without backup", %{project: project} do
      mock_source_file(project, "f1.ex", "line1\nline2")

      canned_agent(fn AI.Agent.FileInfo, args ->
        {:ok, "RESP for #{args.file}"}
      end)

      {:ok, output} = AI.Tools.File.Info.call(%{"files" => ["f1.ex"], "question" => "Q"})
      assert output =~ "Hashline identifiers"
      assert output =~ "## File\nf1.ex"
      assert output =~ "## Result\nRESP for f1.ex"
    end

    test "success path with backup and multiple files ordering", %{project: project} do
      # The first file's name follows the backup convention, so the real
      # BackupFile service annotates its block; the second stays plain.
      mock_source_file(project, "x.ex.0.0.bak", "a")
      mock_source_file(project, "y.ex", "b")

      canned_agent(fn AI.Agent.FileInfo, args ->
        {:ok, "ANS for #{args.file}"}
      end)

      {:ok, output} =
        AI.Tools.File.Info.call(%{"files" => ["x.ex.0.0.bak", "y.ex"], "question" => "Q"})

      [block1, block2] = String.split(output, "\n\n-----\n\n")

      # backup block
      assert block1 =~ "## File\nx.ex.0.0.bak"
      assert block1 =~ "## Result"
      assert block1 =~ "[fnord backup file]"
      assert block1 =~ "ANS for x.ex.0.0.bak"

      # y.ex block
      assert block2 =~ "## File\ny.ex"
      assert block2 =~ "## Result"
      assert block2 =~ "ANS for y.ex"
      refute block2 =~ "backup"
    end

    test "error path when file read fails" do
      {:ok, output} = AI.Tools.File.Info.call(%{"files" => ["bad.ex"], "question" => "Q"})
      assert output =~ "Unable to read the file contents"
      assert output =~ "FILE:  bad.ex"
      assert output =~ "ERROR: :enoent"
    end
  end
end

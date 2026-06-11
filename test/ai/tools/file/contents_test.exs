defmodule AI.Tools.File.ContentsTest do
  use Fnord.TestCase, async: true

  # ---------------------------------------------------------------------------
  # These tests read real files from a real project source root; the canonical
  # accessor (AI.Tools.get_file_contents_with_origin/1) runs for real,
  # including the FileCache and the source-fallback resolution path.
  # ---------------------------------------------------------------------------

  setup do
    project = mock_project("contents_test")

    # The canonical accessor resolves the project via AI.Tools.get_project/0,
    # which rejects projects whose store directory is missing or empty.
    File.mkdir_p!(Store.Project.files_root(project))

    {:ok, project: project}
  end

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
      assert spec.name == "file_contents_tool"
      params = spec.parameters
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

  describe "call/1 - successful read with numbering" do
    test "returns numbered lines wrapped in code fence", %{project: project} do
      mock_source_file(project, "file.txt", "one\ntwo\nthree")

      {:ok, out} = AI.Tools.File.Contents.call(%{"file" => "file.txt"})
      assert out =~ "[file_contents_tool] Contents of file.txt:"
      assert out =~ ~r/1:[0-9a-f]{4}\tone/
      assert out =~ ~r/2:[0-9a-f]{4}\ttwo/
      assert out =~ ~r/3:[0-9a-f]{4}\tthree/
      assert String.contains?(out, "```")
    end
  end

  describe "call/1 - no numbering with slice" do
    test "slice lines 2 to 3 without numbering", %{project: project} do
      mock_source_file(project, "file.txt", "a\nb\nc\nd")

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

  describe "call/1 - default no numbering" do
    test "no numbering by explicit false", %{project: project} do
      mock_source_file(project, "plain", "x\ny")

      {:ok, out} = AI.Tools.File.Contents.call(%{"file" => "plain", "line_numbers" => false})
      refute String.match?(out, ~r/^\d+\t/)
      assert out =~ "x\ny"
    end
  end

  describe "call/1 - slicing to end without end_line" do
    test "slice from line 2 to end", %{project: project} do
      mock_source_file(project, "toend", "a\nb\nc")

      {:ok, out} = AI.Tools.File.Contents.call(%{"file" => "toend", "start_line" => 2})
      assert out =~ ~r/2:[0-9a-f]{4}\tb/
      assert out =~ ~r/3:[0-9a-f]{4}\tc/
    end
  end

  describe "call/1 - start > end returns full content" do
    test "start_line > end_line returns all lines numbered", %{project: project} do
      mock_source_file(project, "rng", "a\nb\nc")

      {:ok, out} =
        AI.Tools.File.Contents.call(%{"file" => "rng", "start_line" => 5, "end_line" => 2})

      assert out =~ ~r/1:[0-9a-f]{4}\ta/
      assert out =~ ~r/3:[0-9a-f]{4}\tc/
    end
  end

  describe "call/1 - includes backup description" do
    test "backup note is included", %{project: project} do
      # The backup-file naming convention alone triggers the annotation;
      # this one was not created this session, so the plain note applies.
      mock_source_file(project, "b.txt.0.0.bak", "ln1")

      {:ok, out} = AI.Tools.File.Contents.call(%{"file" => "b.txt.0.0.bak"})
      assert out =~ "[fnord backup file]"
    end
  end

  describe "call/1 - file not found" do
    test "returns friendly error message" do
      {:error, msg} = AI.Tools.File.Contents.call(%{"file" => "nof"})
      assert msg =~ "does not exist"
      assert msg =~ "nof"
    end
  end

  describe "call/1 - source-fallback for gitignored files" do
    # Simulates a worktree session: the project root override points at an
    # empty "worktree" dir, the original source root holds a gitignored file
    # that was never propagated, and the gitignore check is scripted through
    # the GitCli.Worktree facade mock.
    setup %{project: project} do
      {:ok, worktree} = tmpdir()
      Settings.set_project_root_override(worktree)
      set_config(:original_project_root, project.source_root)

      source_path = mock_source_file(project, "scratch/plan.md", "the plan")

      mock_git_worktree()
      Mox.stub(GitCli.Worktree.Mock, :path_ignored?, fn _root, _path -> true end)

      {:ok, source_path: source_path}
    end

    test "wraps content with source-fallback note explaining where it came from", %{
      source_path: source_path
    } do
      {:ok, out} =
        AI.Tools.File.Contents.call(%{"file" => "scratch/plan.md", "line_numbers" => false})

      assert out =~ "gitignored"
      assert out =~ "not present in"
      assert out =~ source_path
      assert out =~ "the plan"
    end

    test "note instructs LLM to write back via worktree path for accumulator preservation" do
      {:ok, out} =
        AI.Tools.File.Contents.call(%{"file" => "scratch/plan.md", "line_numbers" => false})

      assert out =~ "WITHIN the worktree"
      assert out =~ "scratch/plan.md"
      assert out =~ "tracked and copied back"
    end
  end

  describe "call/1 - other errors" do
    test "propagates non-enoent errors from the accessor" do
      set_config(:project, nil)

      assert AI.Tools.File.Contents.call(%{"file" => "err"}) == {:error, :project_not_set}
    end
  end
end

defmodule AI.Tools.File.EditTest do
  use Fnord.TestCase

  setup do: set_config(workers: 1, quiet: true)
  setup do: {:ok, project: mock_project("blarg")}

  setup do
    AI.Tools.File.Edit.override_confirm_changes(true)
    :ok
  end

  test "basics", %{project: project} do
    _file =
      mock_source_file(project, "bar.txt", """
      How now brown beaurocrat
      Old programmers never die, they just parse on
      The quick brown fox jumps over the lazy dog
      Now is the time for all good men to come to the aid of their country
      """)

    assert {:ok, %{"diff" => diff}} =
             AI.Tools.File.Edit.call(%{
               "file" => "bar.txt",
               "dry_run" => false,
               "edits" => [
                 %{
                   "pattern" => "brown",
                   "replacement" => "red",
                   "line_start" => 1,
                   "line_end" => 2
                 }
               ]
             })

    expected = """
    -How now brown beaurocrat
    +How now red beaurocrat
     Old programmers never die, they just parse on
     The quick brown fox jumps over the lazy dog
     Now is the time for all good men to come to the aid of their country
    """

    assert String.contains?(diff, expected)
  end

  test "error on path traversal outside project" do
    args = %{
      "file" => "../outside.txt",
      "edits" => [%{"pattern" => "foo", "replacement" => "bar"}],
      "dry_run" => true
    }

    # we should get an error, not accidentally copy or mutate something
    assert {:error, :enoent} = AI.Tools.File.Edit.call(args)
  end

  test "symlink inside project is allowed", %{project: project} do
    # Create real file and a symlink to it
    target = mock_source_file(project, "inner.txt", "Z\n")
    link = target |> String.replace(".txt", "_link.txt")
    File.ln_s(target, link)

    args = %{
      "file" => "inner_link.txt",
      "edits" => [%{"pattern" => "Z", "replacement" => "Q"}],
      "dry_run" => false
    }

    assert {:ok, %{"diff" => diff}} = AI.Tools.File.Edit.call(args)
    assert diff =~ "-Z"
    assert diff =~ "+Q"

    # The symlink's target file should also be updated
    assert File.read!(target) == "Q\n"
  end

  test "symlink outside of project is disallowed", %{project: project} do
    # create an outside file and a symlink to it inside the project
    {:ok, outside_dir} = tmpdir()
    outside_file = Path.join(outside_dir, "evil.txt")
    File.write!(outside_file, "secret data")

    link_path = Path.join(project.source_root, "evil_link.txt")
    File.ln_s(outside_file, link_path)

    args = %{
      "file" => "evil_link.txt",
      "edits" => [%{"pattern" => "secret", "replacement" => "public"}],
      "dry_run" => true
    }

    # again, should refuse to follow that symlink
    assert {:error, :enoent} = AI.Tools.File.Edit.call(args)
  end

  test "dry run: leaves file intact and returns diff", %{project: project} do
    original = "foo foo foo\n"
    path = mock_source_file(project, "t.txt", original)

    args = %{
      "file" => "t.txt",
      "edits" => [%{"pattern" => "foo", "replacement" => "bar", "flags" => "g"}],
      "dry_run" => true
    }

    assert {:ok, %{"diff" => diff}} = AI.Tools.File.Edit.call(args)
    assert diff =~ "-foo foo foo"
    assert diff =~ "+bar bar bar"
    # original file must be unchanged
    assert File.read!(path) == original
  end

  test "multiple sequential edits apply in order", %{project: project} do
    original = "a b c\n1 2 3\n"
    path = mock_source_file(project, "multi.txt", original)

    edits = [
      %{"pattern" => "b", "replacement" => "B"},
      %{"pattern" => "1", "replacement" => "ONE"}
    ]

    args = %{"file" => "multi.txt", "edits" => edits, "dry_run" => false}

    assert {:ok, %{"diff" => diff}} = AI.Tools.File.Edit.call(args)
    # Check that both edits appear
    assert diff =~ "+a B c"
    assert diff =~ "+ONE 2 3"
    # On-disk file matches both replacements
    updated = File.read!(path)
    assert updated =~ "a B c"
    assert updated =~ "ONE 2 3"
  end

  test "case‐insensitive replacement via flags 'i'", %{project: project} do
    original = "Hello HELLO HeLlO\n"
    path = mock_source_file(project, "case.txt", original)

    args = %{
      "file" => "case.txt",
      "edits" => [%{"pattern" => "hello", "replacement" => "hi", "flags" => "gi"}],
      "dry_run" => false
    }

    assert {:ok, _} = AI.Tools.File.Edit.call(args)
    # All variants should be replaced
    assert File.read!(path) == "hi hi hi\n"
  end

  test "line range restriction only edits specified lines", %{project: project} do
    content = """
    keep
    change
    keep
    """

    path = mock_source_file(project, "range.txt", content)

    edits = [%{"pattern" => "change", "replacement" => "X", "line_start" => 2, "line_end" => 2}]
    args = %{"file" => "range.txt", "edits" => edits, "dry_run" => false}

    assert {:ok, %{"diff" => diff}} = AI.Tools.File.Edit.call(args)

    # Only the 2nd line should change
    updated = File.read!(path)
    assert String.split(updated, "\n") == ["keep", "X", "keep", ""]

    # Diff should show exactly that one hunk
    assert diff =~ "-change"
    assert diff =~ "+X"
  end

  test "empty edits yields no diff and no modification", %{project: project} do
    content = "unchanged\nlines\n"
    path = mock_source_file(project, "none.txt", content)

    args = %{"file" => "none.txt", "edits" => [], "dry_run" => false}
    assert {:ok, %{"diff" => "No changes"}} = AI.Tools.File.Edit.call(args)

    # File must still match original
    assert File.read!(path) == content
  end

  test "error when target file does not exist" do
    args = %{
      "file" => "missing.txt",
      "edits" => [%{"pattern" => "x", "replacement" => "y"}],
      "dry_run" => false
    }

    assert {:error, _msg} = AI.Tools.File.Edit.call(args)
  end
end

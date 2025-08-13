defmodule HunkTest do
  use Fnord.TestCase

  setup do
    project = mock_project("hunk_test")
    {:ok, %{project: project}}
  end

  test "basics", %{project: project} do
    file =
      mock_source_file(project, "test.txt", """
      This is a test file.
      It has multiple lines.
      This line will be changed.
      So will this one.
      This line will remain unchanged.
      Fin
      """)

    # First, create the hunk targeting lines 3-4
    assert {:ok, hunk} = Hunk.new(file, 3, 4)
    assert Hunk.is_valid?(hunk)
    refute Hunk.is_stale?(hunk)
    refute Hunk.is_staged?(hunk)

    assert {:ok,
            """
            It has multiple lines.
            PRE
            This line will be changed.
            So will this one.
            POST
            This line will remain unchanged.
            """} = Hunk.change_context(hunk, 1, "PRE", "POST")

    # Stage the changes into a temp file
    assert {:ok, hunk} =
             Hunk.stage_changes(hunk, """
             This line has been changed.
             So has this one.
             """)

    assert Hunk.is_valid?(hunk)
    refute Hunk.is_stale?(hunk)
    assert Hunk.is_staged?(hunk)

    # Validate the diff output
    assert {:ok, diff} = Hunk.build_diff(hunk)
    assert diff =~ "-This line will be changed."
    assert diff =~ "-So will this one."
    assert diff =~ "+This line has been changed."
    assert diff =~ "+So has this one."

    # Apply the staged changes to the original file
    assert {:ok, hunk} = Hunk.apply_staged_changes(hunk)
    refute Hunk.is_valid?(hunk)
    assert Hunk.is_stale?(hunk)
    refute Hunk.is_staged?(hunk)
  end
end

defmodule Cmd.AskTest do
  use Fnord.TestCase

  setup do: set_config(workers: 1, quiet: true)
  setup do: set_log_level(:none)
  setup do: {:ok, project: mock_project("test_project")}

  test "prints index status summary when index is not up to date", %{project: project} do
    mock_source_file(project, "file1.txt", "content1")
    mock_source_file(project, "file2.txt", "content2")

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Cmd.Ask.run(%{project: project.name, question: "testing: dummy"}, [], [])
      end)

    assert output =~ "Project Search Index Status"

    lines = output |> String.split("\n", trim: true) |> MapSet.new()

    assert MapSet.subset?(
             MapSet.new(["- Stale:   0", "- New:     2", "- Deleted: 0"]),
             lines
           )

    assert output =~ "Run `fnord index` or `fnord reindex` to update the index."
  end
end

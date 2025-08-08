defmodule AI.Tools.File.EditTest do
  use Fnord.TestCase, async: true

  setup do
    project = mock_project("new-coder-test")
    File.mkdir_p!(project.source_root)

    {:ok, project: project}
  end
end

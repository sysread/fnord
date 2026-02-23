defmodule Services.FileCacheTest do
  use Fnord.TestCase, async: false

  test "get_file_contents uses the cache and reflects file changes" do
    project = mock_project("service-cache-test")

    file_path = Path.join(project.source_root, "svc-file.txt")
    File.mkdir_p!(Path.dirname(file_path))
    File.write!(file_path, "one")

    # Ensure the project's store exists so AI.Tools.get_file_contents can find it
    Store.Project.create(project)

    # Read via AI.Tools.get_file_contents using project-relative path
    rel = Path.relative_to(file_path, project.source_root)

    assert {:ok, "one"} = AI.Tools.get_file_contents(rel)

    # Now change the file
    File.write!(file_path, "two")

    # Second read should reflect updated content (cache invalidated)
    assert {:ok, "two"} = AI.Tools.get_file_contents(rel)
  end
end

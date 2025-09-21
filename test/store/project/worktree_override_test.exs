defmodule Store.Project.WorktreeOverrideTest do
  use Fnord.TestCase, async: false

  setup do
    Settings.set_project_root_override(nil)
    on_exit(fn -> Settings.set_project_root_override(nil) end)
    :ok
  end

  setup do
    # Apply a temporary worktree override
    Settings.set_project_root_override("/my/wt")

    # Ensure no existing project data for "foo"
    settings = Settings.new()
    Settings.delete_project_data(settings, "foo")

    :ok
  end

  test "new/2 honors worktree override" do
    project = Store.Project.new("foo", "/store/foo")
    assert project.source_root == Path.expand("/my/wt")
  end
end

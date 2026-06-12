defmodule AI.Tools.ListProjectsTest do
  use Fnord.TestCase, async: true

  alias AI.Tools.ListProjects

  describe "call/1" do
    test "returns all projects when no project is selected" do
      # Ensure no project is selected for this test.
      Services.Globals.put_env(:fnord, :project, nil)

      home = Settings.get_user_home()
      path = Path.join([home, ".fnord", "settings.json"])

      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        SafeJson.encode!(%{
          "projects" => %{"alpha" => %{"root" => "/tmp/a"}, "beta" => %{"root" => "/tmp/b"}}
        })
      )

      assert {:ok, ["alpha", "beta"]} = ListProjects.call(%{})
    end

    test "excludes the currently selected project" do
      Services.Globals.put_env(:fnord, :project, "beta")

      home = Settings.get_user_home()
      path = Path.join([home, ".fnord", "settings.json"])

      File.mkdir_p!(Path.dirname(path))

      File.write!(
        path,
        SafeJson.encode!(%{
          "projects" => %{"alpha" => %{"root" => "/tmp/a"}, "beta" => %{"root" => "/tmp/b"}}
        })
      )

      assert {:ok, ["alpha"]} = ListProjects.call(%{})
    end
  end

  describe "ui_note_on_result/2" do
    # Note: in production this is called by AI.Tools.on_tool_result/4 with the
    # POST-encoding string from perform_tool_call/3, not the raw list.
    # Earlier versions of this test passed a raw list and `length/1` happened
    # to work; in real usage the model crashed because `result` is a JSON
    # string.
    test "counts projects from the JSON-encoded result" do
      result = SafeJson.encode!(["a", "b", "c"])

      assert {"Projects listed", "Found 3 other project(s)"} =
               ListProjects.ui_note_on_result(%{}, result)
    end

    test "falls back to 0 on unexpected result shape (defensive)" do
      assert {"Projects listed", "Found 0 other project(s)"} =
               ListProjects.ui_note_on_result(%{}, "not json")
    end

    test "falls back to 0 on a JSON value that isn't a list" do
      assert {"Projects listed", "Found 0 other project(s)"} =
               ListProjects.ui_note_on_result(%{}, ~s({"unexpected": "shape"}))
    end
  end
end

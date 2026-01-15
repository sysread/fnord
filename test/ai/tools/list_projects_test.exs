defmodule AI.Tools.ListProjectsTest do
  use Fnord.TestCase, async: false

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
        Jason.encode!(%{
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
        Jason.encode!(%{
          "projects" => %{"alpha" => %{"root" => "/tmp/a"}, "beta" => %{"root" => "/tmp/b"}}
        })
      )

      assert {:ok, ["alpha"]} = ListProjects.call(%{})
    end
  end

  describe "ui_note_on_result/2" do
    test "includes project count" do
      assert {"Projects listed", "Found 3 other project(s)"} =
               ListProjects.ui_note_on_result(%{}, ["a", "b", "c"])
    end
  end
end

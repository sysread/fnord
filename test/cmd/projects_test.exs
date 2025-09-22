defmodule Cmd.ProjectsTest do
  use Fnord.TestCase, async: false

  setup do: set_log_level(:none)

  describe "run/3" do
    test "lists all configured projects" do
      # Create several projects
      p1 = mock_project("proj_alpha")
      p2 = mock_project("proj_beta")
      p3 = mock_project("proj_gamma")

      # Ensure Settings knows about these projects
      # mock_project persists settings via Store.Project.save_settings/3
      # Now run the command and capture output
      {stdout, _stderr} = capture_all(fn -> Cmd.Projects.run(%{}, [], []) end)

      lines = stdout |> String.split("\n", trim: true) |> Enum.sort()

      assert Enum.sort([p1.name, p2.name, p3.name]) == lines
    end

    test "prints nothing when there are no projects" do
      # Ensure a clean env; no projects configured in this fresh test process
      {stdout, _stderr} = capture_all(fn -> Cmd.Projects.run(%{}, [], []) end)
      lines = stdout |> String.split("\n", trim: true)
      assert lines == []
    end
  end
end

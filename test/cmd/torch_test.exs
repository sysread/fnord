defmodule Cmd.TorchTest do
  use Fnord.TestCase, async: false

  setup do: set_log_level(:none)

  describe "run/3" do
    test "deletes project store and removes settings" do
      project = mock_project("torch_proj")
      # Initialize store content so there is something to delete
      _ = Store.Project.create(project)
      assert File.exists?(project.store_path)

      # Sanity: project exists in settings
      assert Settings.get_project(Settings.new()) ==
               {:ok, %{"name" => project.name, "root" => project.source_root, "exclude" => []}}

      # Execute torch
      Cmd.Torch.run(%{}, [], [])

      # Store dir removed
      refute File.exists?(project.store_path)

      # Settings entry removed
      assert Settings.get_project(Settings.new()) == {:error, :project_not_found}
    end

    test "returns error when project not set" do
      Services.Globals.put_env(:fnord, :project, nil)
      result = Cmd.Torch.run(%{}, [], [])
      assert result == {:error, :project_not_set}
    end
  end
end

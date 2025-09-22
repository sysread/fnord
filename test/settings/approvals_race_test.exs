defmodule Settings.Approvals.RaceTest do
  use Fnord.TestCase, async: false

  setup do
    project = mock_project("blarg")
    %{project: project}
  end

  describe "approval additions don't lose concurrent updates" do
    test "two processes adding different approvals to same kind", %{home_dir: _} do
      # Start with empty approvals
      Settings.new()

      # Two processes add different approvals concurrently
      task1 =
        Services.Globals.Spawn.async(fn ->
          Settings.new()
          |> Settings.Approvals.approve(:global, "shell", "git status")
        end)

      task2 =
        Services.Globals.Spawn.async(fn ->
          Settings.new()
          |> Settings.Approvals.approve(:global, "shell", "git log")
        end)

      Task.await(task1, 5000)
      Task.await(task2, 5000)

      # Both should be present
      final = Settings.Approvals.get_approvals(Settings.new(), :global, "shell")
      assert "git status" in final
      assert "git log" in final
    end

    test "many processes adding approvals concurrently", %{home_dir: _} do
      # Start with some existing approvals
      Settings.new()
      |> Settings.Approvals.approve(:global, "shell", "existing_1")
      |> Settings.Approvals.approve(:global, "shell", "existing_2")

      # Many processes add approvals concurrently
      tasks =
        for i <- 1..10 do
          Services.Globals.Spawn.async(fn ->
            Settings.new()
            |> Settings.Approvals.approve(:global, "shell", "cmd_#{i}")
          end)
        end

      Enum.each(tasks, fn task -> Task.await(task, 10000) end)

      # All should be present
      final = Settings.Approvals.get_approvals(Settings.new(), :global, "shell")
      assert "existing_1" in final
      assert "existing_2" in final

      for i <- 1..10 do
        assert "cmd_#{i}" in final
      end
    end

    test "concurrent approvals to different kinds don't interfere", %{home_dir: _} do
      # Multiple processes updating different kinds
      tasks = [
        Services.Globals.Spawn.async(fn ->
          Settings.new()
          |> Settings.Approvals.approve(:global, "shell", "git status")
        end),
        Services.Globals.Spawn.async(fn ->
          Settings.new()
          |> Settings.Approvals.approve(:global, "edit", "*.ex")
        end),
        Services.Globals.Spawn.async(fn ->
          Settings.new()
          |> Settings.Approvals.approve(:global, "shell_full", "^find.*")
        end)
      ]

      Enum.each(tasks, fn task -> Task.await(task, 5000) end)

      # Each kind should have its approval
      settings = Settings.new()
      assert Settings.Approvals.get_approvals(settings, :global, "shell") == ["git status"]
      assert Settings.Approvals.get_approvals(settings, :global, "edit") == ["*.ex"]
      assert Settings.Approvals.get_approvals(settings, :global, "shell_full") == ["^find.*"]
    end
  end
end

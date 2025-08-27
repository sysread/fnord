defmodule Cmd.ConfigTest do
  use Fnord.TestCase

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  # Enable logger output for error testing  
  setup do
    old_level = Logger.level()
    Logger.configure(level: :error)
    on_exit(fn -> Logger.configure(level: old_level) end)

    mock_project("config_test_project")

    :ok
  end

  describe "set command" do
    test "requires project option" do
      log =
        capture_log(fn ->
          Cmd.Config.run([], [:set], [])
        end)

      assert log =~ "Project option is required"
    end

    test "works with existing project" do
      project = mock_project("config_test_project")
      # Create store directory to make project exist in store
      File.mkdir_p!(project.store_path)
      File.write!(Path.join(project.store_path, "dummy.json"), "{}")

      new_root = "/new/path"

      capture_io(fn ->
        Cmd.Config.run([project: project.name, root: new_root], [:set], [])
      end)

      # Verify the change was applied
      {:ok, updated_project} = Store.get_project(project.name)
      assert updated_project.source_root == Path.expand(new_root)
    end

    test "shows error for nonexistent project" do
      log =
        capture_log(fn ->
          Cmd.Config.run([project: "nonexistent", root: "/test"], [:set], [])
        end)

      assert log =~ "does not exist"
    end
  end

  describe "error handling" do
    test "unknown subcommand shows error" do
      log =
        capture_log(fn ->
          Cmd.Config.run([], ["unknown"], [])
        end)

      assert log =~ "Unknown subcommand"
    end

    test "no subcommand shows error" do
      log =
        capture_log(fn ->
          Cmd.Config.run([], [], [])
        end)

      assert log =~ "No subcommand specified"
    end
  end

  describe "approvals command" do
    setup do
      File.rm_rf!(Settings.settings_file())
      :ok
    end

    test "lists global approvals when --global" do
      # seed a pattern
      Settings.new() |> Settings.Approvals.approve(:global, "shell", "ls.*")

      output =
        capture_io(fn ->
          Cmd.Config.run(%{global: true}, [:approvals], [])
        end)

      assert {:ok, %{"shell" => ["ls.*"]}} = Jason.decode(output)
    end

    test "lists project approvals by default" do
      mock_project("proj1")
      Settings.set_project("proj1")
      Settings.new() |> Settings.Approvals.approve(:project, "shell", "foo.*")

      output =
        capture_io(fn ->
          Cmd.Config.run(%{}, [:approvals], [])
        end)

      assert {:ok, %{"shell" => ["foo.*"]}} = Jason.decode(output)
    end

    test "lists both when both --global and --project" do
      mock_project("proj1")
      Settings.set_project("proj1")
      Settings.new() |> Settings.Approvals.approve(:project, "shell", "foo.*")
      Settings.new() |> Settings.Approvals.approve(:global, "shell", "ls.*")

      output =
        capture_io(fn ->
          Cmd.Config.run(%{global: true, project: "proj1"}, [:approvals], [])
        end)

      assert {:ok,
              %{
                "shell" => %{
                  "global" => ["ls.*"],
                  "project" => ["foo.*"]
                }
              }} = Jason.decode(output)
    end
  end

  describe "approve command" do
    setup do
      File.rm_rf!(Settings.settings_file())
      :ok
    end

    test "adds to global scope" do
      out =
        capture_io(fn ->
          Cmd.Config.run(%{kind: "shell", global: true}, [:approve], ["echo.*"])
        end)

      assert {:ok, %{"shell" => ["echo.*"]}} = Jason.decode(out)
    end

    test "adds to project scope by default" do
      mock_project("prj")
      Settings.set_project("prj")

      out =
        capture_io(fn ->
          Cmd.Config.run(%{kind: "shell"}, [:approve], ["foo.*"])
        end)

      assert {:ok, %{"shell" => ["foo.*"]}} = Jason.decode(out)
    end

    test "requires --kind" do
      log =
        capture_log(fn ->
          Cmd.Config.run(%{}, [:approve], ["x"])
        end)

      assert log =~ "Missing --kind"
    end

    test "errors with both --global and --project" do
      log =
        capture_log(fn ->
          Cmd.Config.run(%{kind: "k", global: true, project: "p"}, [:approve], ["x"])
        end)

      assert log =~ "Cannot use both --global and --project"
    end
  end
end

defmodule Cmd.ConfigApprovalsTest do
  use Fnord.TestCase
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  alias Cmd.Config.Approvals

  setup do
    File.rm_rf!(Settings.settings_file())
    :ok
  end

  # Enable logger for capturing error messages in tests
  setup do
    old_level = Logger.level()
    Logger.configure(level: :error)
    on_exit(fn -> Logger.configure(level: old_level) end)
    :ok
  end

  describe "list subcommand" do
    test "lists global approvals when --global" do
      Settings.new() |> Settings.Approvals.approve(:global, "shell", "ls.*")
      output = capture_io(fn -> Approvals.run(%{global: true}, [:approvals], []) end)
      assert {:ok, %{"shell" => ["ls.*"]}} = Jason.decode(output)
    end

    test "lists project approvals by default" do
      mock_project("proj1")
      Settings.set_project("proj1")
      Settings.new() |> Settings.Approvals.approve(:project, "shell", "foo.*")
      output = capture_io(fn -> Approvals.run(%{}, [:approvals], []) end)
      assert {:ok, %{"shell" => ["foo.*"]}} = Jason.decode(output)
    end

    test "lists merged view when both --global and --project" do
      mock_project("proj1")
      Settings.set_project("proj1")
      Settings.new() |> Settings.Approvals.approve(:global, "shell", "ls.*")
      Settings.new() |> Settings.Approvals.approve(:project, "shell", "foo.*")

      output =
        capture_io(fn -> Approvals.run(%{global: true, project: "proj1"}, [:approvals], []) end)

      assert {:ok, %{"shell" => %{"global" => ["ls.*"], "project" => ["foo.*"]}}} =
               Jason.decode(output)
    end
  end

  describe "approve subcommand" do
    test "errors when missing --kind" do
      log = capture_log(fn -> Approvals.run(%{}, [:approve], ["pattern"]) end)
      assert log =~ "Missing --kind"
    end

    test "errors when both --global and --project flags are given" do
      log =
        capture_log(fn ->
          Approvals.run(%{kind: "shell", global: true, project: "proj"}, [:approve], ["x"])
        end)

      assert log =~ "Cannot use both --global and --project"
    end

    test "adds to global scope" do
      out =
        capture_io(fn ->
          Approvals.run(%{kind: "shell", global: true}, [:approve], ["echo.*"])
        end)

      assert {:ok, %{"shell" => ["echo.*"]}} = Jason.decode(out)
    end

    test "adds to project scope by default" do
      mock_project("prj")
      Settings.set_project("prj")
      out = capture_io(fn -> Approvals.run(%{kind: "shell"}, [:approve], ["foo.*"]) end)
      assert {:ok, %{"shell" => ["foo.*"]}} = Jason.decode(out)
    end

    test "invalid regex returns an error" do
      log =
        capture_log(fn -> Approvals.run(%{kind: "shell", global: true}, [:approve], ["("]) end)

      assert log =~ "Invalid regex"
    end
  end

  describe "approve via opts[:pattern]" do
    test "adds to global when pattern in opts" do
      out =
        capture_io(fn ->
          Approvals.run(%{kind: "shell", global: true, pattern: "x.*"}, [:approve], [])
        end)

      assert {:ok, %{"shell" => ["x.*"]}} = Jason.decode(out)
    end

    test "error when no pattern provided" do
      log =
        capture_log(fn ->
          Approvals.run(%{kind: "shell"}, [:approve], [])
        end)

      assert log =~ "Pattern is required"
    end
  end
end

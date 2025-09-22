defmodule Cmd.NotesTest do
  use Fnord.TestCase, async: false
  import ExUnit.CaptureLog

  setup do: set_log_level(:none)
  setup do: {:ok, project: mock_project("notes_proj")}

  describe "run/3 show notes" do
    test "prints notes content when notes exist", %{project: project} do
      # Ensure project exists before writing notes
      _ = Store.Project.create(project)
      :ok = Store.Project.Notes.write("hello notes\nthis is fine\n")

      {stdout, _stderr} = capture_all(fn -> Cmd.Notes.run(%{}, [], []) end)

      # UI.say prints the content as-is via UI.Output.Mock
      assert stdout =~ "hello notes"
      assert stdout =~ "this is fine"
    end

    test "warns when no notes exist", %{project: _project} do
      # Ensure warning level and clean state
      set_log_level(:warning)
      :ok = Store.Project.Notes.reset()

      log = capture_log(fn -> Cmd.Notes.run(%{}, [], []) end)

      assert log =~ "No notes found. Please run `prime` first to gather information."
    end
  end

  describe "run/3 --reset" do
    test "resets notes when confirmed", %{project: project} do
      # Ensure project exists and seed notes
      _ = Store.Project.create(project)
      :ok = Store.Project.Notes.write("seed\n")
      # Stub confirmation to always confirm via TestStub
      Mox.stub(UI.Output.Mock, :confirm, fn msg, _default ->
        UI.Output.TestStub.confirm(msg, true)
      end)

      {stdout, _stderr} = capture_all(fn -> Cmd.Notes.run(%{reset: true}, [], []) end)

      assert stdout =~ "Are you sure you want to delete all notes for #{project.name}?"
      assert stdout =~ "Resetting notes for `#{project.name}`:"
      assert stdout =~ "✓ Notes reset"
    end

    test "aborts reset when not confirmed", %{project: project} do
      # There are no notes needed for this path; confirm default is false in TestStub
      {stdout, _stderr} = capture_all(fn -> Cmd.Notes.run(%{reset: true}, [], []) end)

      assert stdout =~ "Are you sure you want to delete all notes for #{project.name}?"
      assert stdout =~ "Aborted"
    end
  end
end

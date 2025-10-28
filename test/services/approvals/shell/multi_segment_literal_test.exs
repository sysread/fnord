defmodule Services.Approvals.Shell.MultiSegmentLiteralTest do
  use Fnord.TestCase, async: false

  setup do
    Settings.new() |> Settings.update(:approvals, fn _ -> %{} end)
    :ok = :meck.new(UI, [:passthrough])
    :meck.expect(UI, :is_tty?, fn -> false end)

    on_exit(fn ->
      try do
        :meck.unload(UI)
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  test "project literal 'gh pr view' auto-approves 'gh pr view 123'" do
    mock_project("proj")
    Settings.set_project("proj")
    Settings.new() |> Settings.Approvals.approve(:project, "shell", "gh pr view")

    state = %{session: []}
    args = {"|", [%{"command" => "gh", "args" => ["pr", "view", "123"]}], "test"}

    assert {:approved, _} = Services.Approvals.Shell.confirm(state, args)
  end

  test "session literal 'gh pr view' auto-approves" do
    state = %{session: [{:prefix, "gh pr view"}]}
    args = {"|", [%{"command" => "gh", "args" => ["pr", "view", "123"]}], "test"}
    assert {:approved, _} = Services.Approvals.Shell.confirm(state, args)
  end

  test "back-compat: 'gh pr' still approves 'gh pr view 123'" do
    mock_project("proj")
    Settings.set_project("proj")
    Settings.new() |> Settings.Approvals.approve(:project, "shell", "gh pr")

    state = %{session: []}
    args = {"|", [%{"command" => "gh", "args" => ["pr", "view", "123"]}], "test"}

    assert {:approved, _} = Services.Approvals.Shell.confirm(state, args)
  end

  test "'gh pr view' does not approve other subcommands" do
    mock_project("proj")
    Settings.set_project("proj")
    Settings.new() |> Settings.Approvals.approve(:project, "shell", "gh pr view")

    state = %{session: []}
    args = {"|", [%{"command" => "gh", "args" => ["pr", "checkout", "123"]}], "test"}

    assert {:denied, _reason, _} = Services.Approvals.Shell.confirm(state, args)
  end

  test "regex approvals remain unchanged" do
    mock_project("proj")
    Settings.set_project("proj")
    Settings.new() |> Settings.Approvals.approve(:project, "shell_full", "^find(?!.*-exec).+$")

    state = %{session: []}
    args = {"|", [%{"command" => "find", "args" => [".", "-name", "*.exs"]}], "test"}

    assert {:approved, _} = Services.Approvals.Shell.confirm(state, args)
  end
end

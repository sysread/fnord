defmodule Services.Approvals.Shell.MultiSegmentLiteralTest do
  use Fnord.TestCase, async: true

  setup do
    Settings.new() |> Settings.update(:approvals, fn _ -> %{} end)
    set_config(:is_tty, false)

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

  test "customize skips prompt when persisted literal approval already covers sed -n" do
    mock_project("proj")
    Settings.set_project("proj")
    Settings.new() |> Settings.Approvals.approve(:project, "shell", "sed -n")

    state = %{session: []}
    stages = [{"sed", "sed -n 1,20p README.md"}]

    assert {:approved, ^state} = Services.Approvals.Shell.customize(state, stages)
  end

  test "customize skips prompt when persisted regex approval already covers the full command" do
    mock_project("proj")
    Settings.set_project("proj")
    Settings.new() |> Settings.Approvals.approve(:project, "shell_full", "^find(?!.*-exec).+$")

    state = %{session: []}

    stages = [
      {"find", "find . -name *.exs"},
      {"find", "find lib -name *.ex"}
    ]

    assert {:approved, ^state} = Services.Approvals.Shell.customize(state, stages)
  end

  test "customize still prompts once when one stage under a shared prefix is not covered" do
    mock_project("proj")
    Settings.set_project("proj")
    Settings.new() |> Settings.Approvals.approve(:project, "shell", "gh pr view")
    set_config(:is_tty, true)
    set_config(:quiet, false)

    state = %{session: []}

    stages = [
      {"gh pr view", "gh pr view 123"},
      {"gh pr view", "gh pr view --comments 123"},
      {"gh pr checkout", "gh pr checkout 123"}
    ]

    stub(UI.Output.Mock, :prompt, fn _msg, _opts -> "" end)

    stub(UI.Output.Mock, :choose, fn
      "Choose approval scope for:\n    gh pr checkout\n", _opts ->
        "Approve for this session"
    end)

    assert {:approved, %{session: [{:prefix, "gh pr checkout"}]}} =
             Services.Approvals.Shell.customize(state, stages)
  end
end

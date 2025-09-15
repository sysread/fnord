defmodule Settings.ApprovalsMatchingTest do
  use Fnord.TestCase

  alias Settings.Approvals

  setup do
    # Ensure no persisted settings file remains from prior tests
    File.rm_rf!(Settings.settings_file())
    :ok
  end

  test "unanchored pattern ls.* matches 'ls' and 'ls -l'" do
    settings = Settings.new() |> Approvals.approve(:global, "shell", "ls.*")
    assert Approvals.approved?(settings, "shell", "ls")
    assert Approvals.approved?(settings, "shell", "ls -l")
  end

  test "anchored pattern ^git (status|grep)$ enforces exact matches" do
    pattern = "^git (status|grep)$"
    settings = Settings.new() |> Approvals.approve(:global, "shell", pattern)
    assert Approvals.approved?(settings, "shell", "git status")
    refute Approvals.approved?(settings, "shell", "git status extra")
  end

  test "literal pattern rg matches only 'rg' not 'grep'" do
    settings = Settings.new() |> Approvals.approve(:global, "shell", "rg")
    assert Approvals.approved?(settings, "shell", "rg")
    refute Approvals.approved?(settings, "shell", "grep")
  end
end

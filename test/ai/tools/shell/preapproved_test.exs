defmodule AI.Tools.Shell.PreapprovedTest do
  use Fnord.TestCase, async: false
  alias AI.Tools.Shell

  setup do
    # Ensure any existing meck processes are unloaded before starting new mocks
    try do
      :meck.unload(Services.Approvals)
    rescue
      _ -> :ok
    end

    # Create fresh mocks for each test
    try do
      :meck.new(Services.Approvals, [:passthrough])
    rescue
      _ -> :ok
    end

    on_exit(fn ->
      try do
        :meck.unload(Services.Approvals)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  test "ls skips approval and runs" do
    :meck.expect(Services.Approvals, :confirm, fn _ ->
      flunk("confirm should NOT be called")
    end)

    assert {:ok, result} =
             Shell.call(%{"description" => "list", "command" => "ls", "params" => ["-la"]})

    assert result =~ "Command: `ls -la`"
  end

  test "git log skips approval" do
    :meck.expect(Services.Approvals, :confirm, fn _ ->
      flunk("confirm should NOT be called")
    end)

    assert {:ok, result} =
             Shell.call(%{"description" => "git log", "command" => "git", "params" => ["log"]})

    assert result =~ "Command: `git log`"
  end

  test "git remote still asks approval" do
    :meck.expect(Services.Approvals, :confirm, fn _ ->
      {:ok, :approved}
    end)

    assert {:ok, _} =
             Shell.call(%{"description" => "remote", "command" => "git", "params" => ["remote"]})
  end
end

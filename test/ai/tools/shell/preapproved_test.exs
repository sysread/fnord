defmodule AI.Tools.Shell.PreapprovedTest do
  use ExUnit.Case, async: false
  alias AI.Tools.Shell

  setup do
    # Ensure any existing meck processes are unloaded before starting new mocks
    try do
      :meck.unload(AI.Agent.ShellCmdParser)
    rescue
      _ -> :ok
    end

    try do
      :meck.unload(Services.Approvals)
    rescue
      _ -> :ok
    end

    # Create fresh mocks for each test
    try do
      :meck.new(AI.Agent.ShellCmdParser, [:passthrough])
    rescue
      _ -> :ok
    end

    try do
      :meck.new(Services.Approvals, [:passthrough])
    rescue
      _ -> :ok
    end

    on_exit(fn ->
      try do
        :meck.unload(AI.Agent.ShellCmdParser)
      rescue
        _ -> :ok
      end

      try do
        :meck.unload(Services.Approvals)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  test "ls skips approval and runs" do
    :meck.expect(AI.Agent.ShellCmdParser, :get_response, fn %{shell_cmd: "ls -la"} ->
      {:ok, %{"cmd" => "ls", "args" => ["-la"], "approval_bits" => ["ls"]}}
    end)

    :meck.expect(Services.Approvals, :confirm, fn _ ->
      flunk("confirm should NOT be called")
    end)

    assert {:ok, result} = Shell.call(%{"description" => "list", "cmd" => "ls -la"})
    assert result =~ "Command: `ls -la`"
  end

  test "git log skips approval" do
    :meck.expect(AI.Agent.ShellCmdParser, :get_response, fn %{shell_cmd: "git log"} ->
      {:ok, %{"cmd" => "git", "args" => ["log"], "approval_bits" => ["git", "log"]}}
    end)

    :meck.expect(Services.Approvals, :confirm, fn _ ->
      flunk("confirm should NOT be called")
    end)

    assert {:ok, result} = Shell.call(%{"description" => "git log", "cmd" => "git log"})
    assert result =~ "Command: `git log`"
  end

  test "git remote still asks approval" do
    :meck.expect(AI.Agent.ShellCmdParser, :get_response, fn %{shell_cmd: "git remote"} ->
      {:ok, %{"cmd" => "git", "args" => ["remote"], "approval_bits" => ["git", "remote"]}}
    end)

    :meck.expect(Services.Approvals, :confirm, fn _ ->
      {:ok, :approved}
    end)

    assert {:ok, _} = Shell.call(%{"description" => "remote", "cmd" => "git remote"})
  end
end

defmodule Services.ApprovalsReadOnlyTest do
  use Fnord.TestCase, async: false

  alias Services.Approvals

  # This module tests the ReadOnlyMode implementation specifically  
  setup do
    # Use the ReadOnlyMode implementation for these tests
    Application.put_env(:fnord, :approvals_impl, Services.Approvals.ReadOnlyMode)
    # Ensure quiet mode is set to prevent test output
    Application.put_env(:fnord, :quiet, true)
    # Restart the approvals service to pick up the new implementation
    try do
      GenServer.stop(Services.Approvals, :normal)
    catch
      :exit, _ -> :ok
    end

    {:ok, _pid} = Services.Approvals.start_link()
    :ok
  end

  test "approves pre-approved shell commands" do
    opts = [
      tag: "shell_cmd",
      subject: "ls -la",
      message: "List files",
      detail: "List directory contents"
    ]

    assert {:ok, :approved} = Approvals.confirm(opts)
  end

  test "denies non-approved shell commands" do
    opts = [
      tag: "shell_cmd",
      subject: "rm -rf /",
      message: "Delete everything",
      detail: "This should be denied"
    ]

    assert {:error, msg} = Approvals.confirm(opts)
    assert msg =~ "Shell command denied in read-only mode"
    assert msg =~ "rm -rf /"
  end

  test "denies file operations" do
    opts = [
      tag: "general",
      subject: "edit files",
      message: "Edit project files",
      detail: "This should be denied"
    ]

    assert {:error, msg} = Approvals.confirm(opts)
    assert msg =~ "File operation denied in read-only mode"
    assert msg =~ "edit files"
  end

  test "is_approved? returns true for pre-approved commands" do
    assert Approvals.is_approved?("shell_cmd", "git log")
  end

  test "is_approved? returns false for non-approved commands" do
    refute Approvals.is_approved?("shell_cmd", "rm -rf")
    refute Approvals.is_approved?("general", "edit files")
  end

  test "approve returns error in read-only mode" do
    assert {:error, msg} = Approvals.approve(:session, "shell_cmd", "custom command")
    assert msg =~ "not available in read-only mode"
  end
end

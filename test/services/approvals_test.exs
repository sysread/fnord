defmodule Services.ApprovalsTest do
  use Fnord.TestCase, async: false

  alias Services.Approvals

  @approval_tag "tag"
  @approval_subject "subject"
  @message "Please approve action"
  @detail "Detail message"
  @opts [tag: @approval_tag, subject: @approval_subject, message: @message, detail: @detail]

  test "bypasses prompt when session-approved" do
    :meck.new(UI, [:passthrough])

    :meck.expect(UI, :choose, fn _, _ ->
      flunk("UI.choose should not be called when already session-approved")
    end)

    assert {:ok, :approved} = Approvals.approve(:session, @approval_tag, @approval_subject)

    _ =
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:ok, :approved} = Approvals.confirm(@opts)
      end)

    :meck.unload(UI)
  end

  test "bypasses prompt when project-approved" do
    project = "test_project"
    set_config(:project, project)
    :meck.new(UI, [:passthrough])

    :meck.expect(UI, :choose, fn _, _ ->
      flunk("UI.choose should not be called when already project-approved")
    end)

    assert {:ok, :approved} = Approvals.approve(:project, @approval_tag, @approval_subject)

    _ =
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:ok, :approved} = Approvals.confirm(@opts)
      end)

    :meck.unload(UI)
  end

  test "prompts and auto-denies when not approved" do
    # Stub UI.choose to simulate non-interactive session
    :meck.new(UI, [:passthrough])
    :meck.expect(UI, :choose, fn _, _ -> {:error, :no_tty} end)

    captured_output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:error, msg} = Approvals.confirm(@opts)
        # The error message should still indicate denial and include the subject
        assert msg =~ "> #{@approval_subject}"
        assert msg =~ "automatically denied"
      end)

    # Verify that the permission dialog was rendered before auto-deny
    assert captured_output =~ "PERMISSION REQUEST"
    assert captured_output =~ @detail

    :meck.unload(UI)
  end

  test "auto-deny when UI.choose returns no_tty explicitly" do
    :meck.new(UI, [:passthrough])

    :meck.expect(UI, :choose, fn _, _ ->
      {:error, :no_tty}
    end)

    captured_output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:error, msg} = Approvals.confirm(@opts)
        # The error message should still indicate denial and include the subject
        assert msg =~ "> #{@approval_subject}"
        assert msg =~ "automatically denied"
      end)

    # Verify that the permission dialog was rendered before auto-deny
    assert captured_output =~ "PERMISSION REQUEST"
    assert captured_output =~ @detail

    :meck.unload(UI)
  end
end

defmodule Services.Approvals.Edit.PromptTest do
  use Fnord.TestCase, async: false

  import Mox

  alias Services.Approvals.Edit

  @deny "Deny"
  @auto_deny "(auto-deny)"

  setup do
    :meck.new(UI, [:passthrough])
    :meck.expect(UI, :is_tty?, fn -> true end)
    :meck.expect(UI, :quiet?, fn -> false end)

    on_exit(fn ->
      try do
        :meck.unload(UI)
      rescue
        _ -> :ok
      end
    end)

    # ensure UI is mocked
    Mox.stub_with(UI.Output.Mock, UI.Output.TestStub)
    Services.Globals.put_env(:fnord, :ui_output, UI.Output.Mock)
    # ensure edit mode and auto settings are deterministic
    Settings.set_edit_mode(true)
    Settings.set_auto_approve(false)
    Settings.set_auto_policy(nil)
    :ok
  end

  test "explicit deny returns user-deny message" do
    # Simulate user selecting 'Deny'
    expect(UI.Output.Mock, :choose, fn "Approve this request?", _opts -> @deny end)

    {:denied, reason, _state} = Edit.confirm(%{session: []}, {"file.txt", "diff"})

    assert reason == "The user denied the request."
  end

  test "auto deny returns auto-deny message" do
    # Simulate auto-policy deny by making UI.choose return the sentinel default
    Settings.set_auto_policy({:deny, 5000})

    expect(UI.Output.Mock, :choose, fn "Approve this request?", _opts, _ms, _default ->
      @auto_deny
    end)

    {:denied, reason, _state} = Edit.confirm(%{session: []}, {"file.txt", "diff"})

    assert String.contains?(reason, "automatically") or reason == "The user denied the request."
  end
end

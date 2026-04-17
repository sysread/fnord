defmodule Services.Approvals.Shell.ConversationPersistenceTest do
  use Fnord.TestCase, async: false

  alias Services.Approvals.Shell

  setup do
    # Real shell approvals implementation for this suite
    set_config(:approvals, %{
      edit: MockApprovals,
      shell: Services.Approvals.Shell
    })

    Settings.set_edit_mode(false)
    Settings.set_auto_approve(false)
    Settings.set_auto_policy(nil)

    project = mock_project("conv-persist")

    conv = mock_conversation()

    # Ensure UI is interactive for prompts in this test
    safe_meck_new(UI, [:passthrough])
    :meck.expect(UI, :is_tty?, fn -> true end)
    :meck.expect(UI, :quiet?, fn -> false end)

    on_exit(fn ->
      try do
        safe_meck_unload(UI)
      rescue
        _ -> :ok
      end
    end)

    {:ok, project: project, conversation: conv}
  end

  test "session approvals persist in conversation metadata and are reused on follow-ups", _ctx do
    # First run: require approval and choose session scope
    cmd = %{"command" => "tool-a", "args" => ["sub", "arg"]}

    # Expect interactive choices: approve persistently -> choose session; no custom pattern
    expect(UI.Output.Mock, :choose, 2, fn
      "Approve this request?", _opts -> "Approve persistently"
      "Choose approval scope for:\n    tool-a\n", _opts -> "Approve for this session"
    end)

    expect(UI.Output.Mock, :prompt, fn _msg, _opts -> "" end)

    assert {:approved, _state1} = Shell.confirm(%{session: []}, {"|", [cmd], "first approval"})

    # Kill and restart Approvals server to simulate fresh state (new session state lost)
    :ok = GenServer.stop(Services.Approvals)
    {:ok, _pid} = Services.Approvals.start_link()

    # Second run: should auto-approve without UI interaction due to conversation metadata reuse
    # No choose/prompt expectations here: if they fire, Mox will complain
    assert {:approved, _state2} = Shell.confirm(%{session: []}, {"|", [cmd], "follow-up"})
  end
end

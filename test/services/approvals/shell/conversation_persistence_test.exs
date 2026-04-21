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

  # Regression: persisted :full regex approvals are user-writable on disk.
  # Regex.compile! on an invalid pattern used to crash the Approvals
  # GenServer. The reloader now drops invalid regexes with a warn and
  # continues, so a bad stored pattern degrades to prompting instead of
  # taking down the approval flow.
  test "invalid persisted :full regex does not crash approvals", ctx do
    pid = ctx.conversation.conversation_pid

    Services.Conversation.upsert_conversation_meta(pid, %{
      session_shell_approvals: [%{kind: :full, value: "[unclosed"}]
    })

    Services.Globals.put_env(:fnord, :current_conversation, pid)

    cmd = %{"command" => "tool-unseen", "args" => []}

    expect(UI.Output.Mock, :choose, fn _msg, _opts -> "Deny" end)

    # Must not raise - we expect the :full pattern to be skipped and the
    # unknown command to prompt as usual; the user denies.
    assert {:denied, _reason, _state} =
             Shell.confirm(%{session: []}, {"|", [cmd], "bad-regex reload"})
  end

  # H1 mitigation: inherited persisted approvals are announced to the user
  # once per invocation so a planted or corrupted entry is visible rather
  # than silently auto-approving matching commands.
  test "inherited approvals are announced once per session", ctx do
    pid = ctx.conversation.conversation_pid

    Services.Conversation.upsert_conversation_meta(pid, %{
      session_shell_approvals: [%{kind: :prefix, value: "inherited-cmd"}]
    })

    Services.Globals.put_env(:fnord, :current_conversation, pid)

    cmd = %{"command" => "inherited-cmd", "args" => []}

    announcements = :counters.new(1, [:atomics])

    :meck.expect(UI, :info, fn label, _body ->
      if label == "Shell approvals", do: :counters.add(announcements, 1, 1)
      :ok
    end)

    # Two approval calls in the same process (same Approvals GenServer pid).
    assert {:approved, _} = Shell.confirm(%{session: []}, {"|", [cmd], "first"})
    assert {:approved, _} = Shell.confirm(%{session: []}, {"|", [cmd], "second"})

    # Announced exactly once across the two calls.
    assert :counters.get(announcements, 1) == 1
  end
end

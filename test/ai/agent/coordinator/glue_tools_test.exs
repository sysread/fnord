defmodule AI.Agent.Coordinator.GlueToolsTest do
  # async: false - get_completion boots ad-hoc GenServers whose init code
  # calls Mox-backed facades (gotcha 36), and set_log_level mutates global
  # Logger config.
  use Fnord.TestCase, async: false

  alias AI.Agent.Coordinator.Glue

  setup do
    set_log_level(:none)

    # get_tools probes the git facade for the worktree-tool gate; script it
    # so the repo the suite happens to run in cannot leak into assertions.
    mock_git_cli()
    Mox.stub(GitCli.Mock, :is_git_repo?, fn -> false end)

    :ok
  end

  test "coordinator includes ui tools only when tty and not quiet" do
    set_config(:is_tty, true)
    set_config(:quiet, false)

    for edit <- [false, true] do
      tools = Glue.get_tools(%{edit?: edit})

      assert Map.has_key?(tools, "ui_ask_tool")
      assert Map.has_key?(tools, "ui_choose_tool")
      assert Map.has_key?(tools, "ui_confirm_tool")
    end
  end

  test "coordinator excludes ui tools when not a tty" do
    set_config(:is_tty, false)
    set_config(:quiet, false)

    for edit <- [false, true] do
      tools = Glue.get_tools(%{edit?: edit})

      refute Map.has_key?(tools, "ui_ask_tool")
      refute Map.has_key?(tools, "ui_choose_tool")
      refute Map.has_key?(tools, "ui_confirm_tool")
    end
  end

  test "coordinator excludes ui tools when quiet" do
    set_config(:is_tty, true)
    set_config(:quiet, true)

    for edit <- [false, true] do
      tools = Glue.get_tools(%{edit?: edit})

      refute Map.has_key?(tools, "ui_ask_tool")
      refute Map.has_key?(tools, "ui_choose_tool")
      refute Map.has_key?(tools, "ui_confirm_tool")
    end
  end

  test "coordinator worktree tool is gated on edit mode and git repo" do
    set_config(:is_tty, false)
    set_config(:quiet, false)
    Mox.stub(GitCli.Mock, :is_git_repo?, fn -> true end)

    edit_tools = Glue.get_tools(%{edit?: true})
    non_edit_tools = Glue.get_tools(%{edit?: false})

    assert Map.has_key?(edit_tools, "git_worktree_tool")
    refute Map.has_key?(non_edit_tools, "git_worktree_tool")
  end

  test "coordinator worktree tool is omitted outside git repos" do
    set_config(:is_tty, false)
    set_config(:quiet, false)
    Mox.stub(GitCli.Mock, :is_git_repo?, fn -> false end)

    tools = Glue.get_tools(%{edit?: true})

    refute Map.has_key?(tools, "git_worktree_tool")
  end

  describe "validation integration" do
    setup do
      _project = mock_project("glue_tools_test")

      # Glue drives a real conversation server; the model's turns are canned
      # at the completion-API boundary so the real completion loop, tool
      # dispatch, and Validation.Rules all run for real.
      %{conversation_pid: conversation_pid} = mock_conversation()

      {:ok, conversation_pid: conversation_pid}
    end

    test "does not run validation when no code-modifying tools were used", ctx do
      test_pid = self()

      # Validation's first move is changed-file discovery through the git
      # facade; this probe trips if it fires.
      Mox.stub(GitCli.Mock, :status_short, fn _root ->
        send(test_pid, :validation_probed)
        {:ok, []}
      end)

      canned_completion("done")

      state = fake_coordinator_state(ctx.conversation_pid, edit?: false)

      assert %{last_validation_fingerprint: nil} = Glue.get_completion(state)
      refute_received :validation_probed
    end

    test "records validation fingerprint when code-modifying tools were used", ctx do
      # The model "calls" file_edit_tool once, then wraps up. The real loop
      # dispatches the call; the empty arguments fail central arg validation,
      # which is fine - tools_used counts the call either way, and that is
      # what gates validation.
      stub(AI.CompletionAPI.Mock, :get, fn _model, msgs, _tools, _rf, _web, _verbosity ->
        if Enum.any?(msgs, &match?(%AI.Message.FunctionCall{}, &1)) do
          {:ok, :msg, "done", 0}
        else
          {:ok, :tool, [%{id: 1, function: %{name: "file_edit_tool", arguments: "{}"}}]}
        end
      end)

      # One dirty file, no validation rules configured for the project: the
      # run lands on {:ok, :no_rules, files, fingerprint} and the fingerprint
      # must be recorded on the state for dedup of the next round's report.
      Mox.stub(GitCli.Mock, :status_short, fn _root -> {:ok, [" M lib/foo.ex"]} end)

      state = fake_coordinator_state(ctx.conversation_pid, edit?: true)
      expected = Validation.Rules.fingerprint(["lib/foo.ex"])

      assert %{last_validation_fingerprint: ^expected} = Glue.get_completion(state)
    end
  end

  defp fake_coordinator_state(conversation_pid, opts) do
    model = AI.Model.smart()

    %AI.Agent.Coordinator{
      agent: %AI.Agent{impl: AI.Agent.Coordinator, name: "test", named?: true},
      edit?: Keyword.fetch!(opts, :edit?),
      replay: false,
      question: "Q",
      conversation_pid: conversation_pid,
      followup?: false,
      project: "glue_tools_test",
      model: model,
      fonz: false,
      last_response: nil,
      steps: [],
      usage: 0,
      context: model.context,
      intuition: nil,
      editing_tools_used: false,
      last_validation_fingerprint: nil,
      interrupts: AI.Agent.Coordinator.Interrupts.new()
    }
  end
end

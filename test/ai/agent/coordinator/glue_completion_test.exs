defmodule AI.Agent.Coordinator.GlueCompletionTest do
  # Sync: set_log_level reconfigures the VM-global Logger level for the
  # duration of each test, which would leak into concurrently running tests.
  use Fnord.TestCase, async: false

  alias AI.Agent.Coordinator.Glue

  @fonz_prompt """
  Fonz mode is enabled. Speak as though you were The Fonz: cool, confident, and lightly in-character.
  Keep the answer useful and technically accurate, and do not let the persona crowd out the substance.
  """

  setup do
    set_log_level(:none)
    _project = mock_project("glue_completion_test")

    # Glue drives a real conversation server: get_messages/save/replace_msgs
    # run against the per-test store, and the tree-local Interrupts service
    # answers pending?/1 for the pid.
    %{conversation_pid: conversation_pid} = mock_conversation()

    {:ok, conversation_pid: conversation_pid}
  end

  # Regression: the Coordinator's Glue layer used to pass `:model` (with a
  # verbosity field mutated by AI.Model.with_verbosity/2) but NOT `:verbosity`
  # into AI.Agent.get_completion. AI.Completion.new/1 reads :verbosity as a
  # standalone opt, so the -V/--frippery user flag was silently a no-op on
  # the Coordinator path. The stubs below capture the model and verbosity at
  # the completion-API boundary, proving the flag survives the whole trip
  # through Glue AND the real completion loop to the wire layer.
  test "forwards state.model.verbosity through to the completion API", ctx do
    test_pid = self()

    stub(AI.CompletionAPI.Mock, :get, fn model, _msgs, _tools, _rf, _web, verbosity ->
      send(test_pid, {:completion_call, model, verbosity})
      {:ok, :msg, "ok", 0}
    end)

    model = AI.Model.smart() |> AI.Model.with_verbosity(:low)
    state = fake_coordinator_state(model, ctx.conversation_pid)

    Glue.get_completion(state)

    assert_received {:completion_call, ^model, :low}
  end

  test "forwards nil verbosity when the user did not pass -V", ctx do
    test_pid = self()

    stub(AI.CompletionAPI.Mock, :get, fn model, _msgs, _tools, _rf, _web, verbosity ->
      send(test_pid, {:completion_call, model, verbosity})
      {:ok, :msg, "ok", 0}
    end)

    model = AI.Model.smart()
    state = fake_coordinator_state(model, ctx.conversation_pid)

    Glue.get_completion(state)

    assert_received {:completion_call, ^model, nil}
  end

  test "injects the explicit Fonz persona note into completion messages", ctx do
    test_pid = self()

    stub(AI.CompletionAPI.Mock, :get, fn _model, msgs, _tools, _rf, _web, _verbosity ->
      send(test_pid, {:completion_call, msgs})
      {:ok, :msg, "ok", 0}
    end)

    state = fake_coordinator_state(AI.Model.smart(), ctx.conversation_pid)

    Services.Conversation.replace_msgs(
      [
        AI.Util.system_msg("Your name is The Fonz."),
        AI.Util.system_msg(String.trim(@fonz_prompt))
      ],
      ctx.conversation_pid
    )

    Glue.get_completion(state)

    assert_received {:completion_call, msgs}
    assert Enum.any?(msgs, fn msg -> msg.content == String.trim(@fonz_prompt) end)
  end

  defp fake_coordinator_state(model, conversation_pid) do
    %AI.Agent.Coordinator{
      agent: %AI.Agent{impl: AI.Agent.Coordinator, name: "test", named?: true},
      edit?: false,
      replay: false,
      question: "Q",
      conversation_pid: conversation_pid,
      followup?: false,
      project: "glue_completion_test",
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

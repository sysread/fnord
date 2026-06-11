defmodule AI.Agent.Coordinator.GlueCompletionTest do
  use Fnord.TestCase, async: false

  alias AI.Agent.Coordinator.Glue

  setup do
    set_log_level(:none)
    _project = mock_project("glue_completion_test")

    safe_meck_new(Services.Conversation, [:passthrough, :no_link, :non_strict])
    safe_meck_new(Services.Conversation.Interrupts, [:passthrough, :no_link, :non_strict])

    on_exit(fn ->
      safe_meck_unload(Services.Conversation.Interrupts)
      safe_meck_unload(Services.Conversation)
    end)

    :meck.expect(Services.Conversation, :get_messages, fn _pid -> [] end)

    :meck.expect(Services.Conversation, :save, fn pid ->
      {:ok, %{id: "conv-test-#{inspect(pid)}"}}
    end)

    :meck.expect(Services.Conversation, :replace_msgs, fn _msgs, _pid -> :ok end)
    :meck.expect(Services.Conversation, :append_msg, fn _msg, _pid -> :ok end)
    :meck.expect(Services.Conversation.Interrupts, :pending?, fn _pid -> false end)

    :ok
  end

  # Regression: the Coordinator's Glue layer used to pass `:model` (with a
  # verbosity field mutated by AI.Model.with_verbosity/2) but NOT `:verbosity`
  # into AI.Agent.get_completion. AI.Completion.new/1 reads :verbosity as a
  # standalone opt, so the -V/--frippery user flag was silently a no-op on
  # the Coordinator path. The stubs below capture the model and verbosity at
  # the completion-API boundary, proving the flag survives the whole trip
  # through Glue AND the real completion loop to the wire layer.
  test "forwards state.model.verbosity through to the completion API" do
    test_pid = self()

    stub(AI.CompletionAPI.Mock, :get, fn model, _msgs, _tools, _rf, _web, verbosity ->
      send(test_pid, {:completion_call, model, verbosity})
      {:ok, :msg, "ok", 0}
    end)

    model = AI.Model.smart() |> AI.Model.with_verbosity(:low)
    state = fake_coordinator_state(model)

    Glue.get_completion(state)

    assert_received {:completion_call, ^model, :low}
  end

  test "forwards nil verbosity when the user did not pass -V" do
    test_pid = self()

    stub(AI.CompletionAPI.Mock, :get, fn model, _msgs, _tools, _rf, _web, verbosity ->
      send(test_pid, {:completion_call, model, verbosity})
      {:ok, :msg, "ok", 0}
    end)

    model = AI.Model.smart()
    state = fake_coordinator_state(model)

    Glue.get_completion(state)

    assert_received {:completion_call, ^model, nil}
  end

  defp fake_coordinator_state(model) do
    %AI.Agent.Coordinator{
      agent: %AI.Agent{impl: AI.Agent.Coordinator, name: "test", named?: true},
      edit?: false,
      replay: false,
      question: "Q",
      conversation_pid: self(),
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

defmodule AI.Agent.Coordinator.MemoryTest do
  use Fnord.TestCase, async: false

  alias AI.Agent.Coordinator.Memory, as: CoordinatorMemory

  setup do
    set_log_level(:none)
    _project = mock_project("coordinator_memory_test")
    %{conversation_pid: conversation_pid} = mock_conversation()

    {:ok, conversation_pid: conversation_pid}
  end

  describe "spool_mnemonics/1" do
    test "tolerates nil intuition and still injects recalled memories", ctx do
      {:ok, mem} =
        Memory.new(:global, "Recallable", "A stable thing worth remembering.", ["memory"])

      assert {:ok, _saved} = Memory.save(mem)

      model = AI.Model.smart()

      state = %AI.Agent.Coordinator{
        agent: %AI.Agent{impl: AI.Agent.Coordinator, name: "test", named?: true},
        edit?: false,
        replay: false,
        question: "  remind me  ",
        conversation_pid: ctx.conversation_pid,
        followup?: false,
        project: "coordinator_memory_test",
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

      assert :ok = CoordinatorMemory.spool_mnemonics(state)

      assert wait_until(fn ->
               messages = Services.Conversation.get_messages(ctx.conversation_pid)

               Enum.any?(messages, fn msg ->
                 msg.role == "assistant" and
                   String.contains?(msg.content, "The user's prompt brings to mind") and
                   String.contains?(msg.content, "Recallable")
               end)
             end)
    end

    test "tolerates nil question and still injects recalled memories", ctx do
      {:ok, mem} =
        Memory.new(:global, "Recallable", "A stable thing worth remembering.", ["memory"])

      assert {:ok, _saved} = Memory.save(mem)

      model = AI.Model.smart()

      state = %AI.Agent.Coordinator{
        agent: %AI.Agent{impl: AI.Agent.Coordinator, name: "test", named?: true},
        edit?: false,
        replay: false,
        question: nil,
        conversation_pid: ctx.conversation_pid,
        followup?: false,
        project: "coordinator_memory_test",
        model: model,
        fonz: false,
        last_response: nil,
        steps: [],
        usage: 0,
        context: model.context,
        intuition: "  useful hunch  ",
        editing_tools_used: false,
        last_validation_fingerprint: nil,
        interrupts: AI.Agent.Coordinator.Interrupts.new()
      }

      assert :ok = CoordinatorMemory.spool_mnemonics(state)

      assert wait_until(fn ->
               messages = Services.Conversation.get_messages(ctx.conversation_pid)

               Enum.any?(messages, fn msg ->
                 msg.role == "assistant" and
                   String.contains?(msg.content, "The user's prompt brings to mind") and
                   String.contains?(msg.content, "Recallable")
               end)
             end)
    end
  end
end

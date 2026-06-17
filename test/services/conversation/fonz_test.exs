defmodule Services.Conversation.FonzTest do
  use Fnord.TestCase, async: false

  import AI.Util

  setup do
    mock_project("conversation_fonz_test")
    Services.Globals.delete_env(:fnord, :yes_count)
    :ok
  end

  describe "fonz naming in completion input" do
    test "injects `Your name is The Fonz.` when yes_count is greater than one" do
      test_pid = self()

      canned_agent(fn AI.Agent.Coordinator, %{agent: agent, conversation_pid: conversation_pid} ->
        assert {:ok, completion} =
                 AI.Completion.new(
                   model: "test-model",
                   name: agent.name,
                   messages: [user_msg("ping")],
                   conversation_pid: conversation_pid
                 )

        send(test_pid, {:captured_msgs, completion.messages})

        {:ok, %{last_response: "ok", usage: 0, context: 0}}
      end)

      Settings.set_yes_count(2)
      assert {:ok, pid} = Services.Conversation.start_link()

      assert {:ok, %{last_response: "ok"}} =
               Services.Conversation.get_response(pid, question: "ping")

      assert_receive {:captured_msgs, msgs}, 1000

      assert Enum.any?(msgs, fn
               %{content: "Your name is The Fonz."} -> true
               _ -> false
             end)
    end

    test "does not inject `Your name is The Fonz.` when yes_count is not greater than one" do
      test_pid = self()

      canned_agent(fn AI.Agent.Coordinator, %{agent: agent, conversation_pid: conversation_pid} ->
        assert {:ok, completion} =
                 AI.Completion.new(
                   model: "test-model",
                   name: agent.name,
                   messages: [user_msg("ping")],
                   conversation_pid: conversation_pid
                 )

        send(test_pid, {:captured_msgs, completion.messages})

        {:ok, %{last_response: "ok", usage: 0, context: 0}}
      end)

      Settings.set_yes_count(1)
      assert {:ok, pid} = Services.Conversation.start_link()

      assert {:ok, %{last_response: "ok"}} =
               Services.Conversation.get_response(pid, question: "ping")

      assert_receive {:captured_msgs, msgs}, 1000

      refute Enum.any?(msgs, fn
               %{content: "Your name is The Fonz."} -> true
               _ -> false
             end)
    end
  end
end

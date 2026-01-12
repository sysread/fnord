defmodule Services.ConversationSaveTest do
  use Fnord.TestCase, async: false

  import AI.Util

  describe "save/1 message filtering" do
    test "drops boilerplate system scaffolding and assistant <think> messages, but preserves name + summary" do
      mock_project("test_project_conversation_save_filtering")
      %{conversation: conversation, conversation_pid: pid} = mock_conversation()

      msgs = [
        # Dropped: non-essential system/developer scaffolding
        AI.Util.system_msg("(system scaffolding that should be dropped)"),

        # Preserved: agent naming line (used to rehydrate agent name)
        AI.Util.system_msg("Your name is Eldon the Echo."),

        # Preserved: compactor summary
        AI.Util.system_msg("Summary of conversation and research thus far: blah blah"),

        # Keep: actual conversation
        AI.Util.user_msg("hello"),

        # Dropped: reasoning traces
        AI.Util.assistant_msg("<think>secret reasoning</think>"),

        # Keep: normal assistant output
        AI.Util.assistant_msg("visible answer")
      ]

      :ok = Services.Conversation.replace_msgs(msgs, pid)

      # Cast is async; poll until the new messages are visible before saving.
      Enum.reduce_while(1..50, nil, fn _, _ ->
        case Services.Conversation.get_messages(pid) do
          ^msgs -> {:halt, :ok}
          _ -> Process.sleep(10)
        end
      end)

      assert {:ok, _} = Services.Conversation.save(pid)

      # Re-read directly from storage to verify what was persisted.
      assert {:ok, saved} =
               Store.Project.Conversation.read(Store.Project.Conversation.new(conversation.id))

      saved_msgs = saved.messages

      # dropped
      refute Enum.any?(
               saved_msgs,
               fn
                 %{content: c} = m when is_system_msg?(m) ->
                   c == "(system scaffolding that should be dropped)"

                 _ ->
                   false
               end
             )

      refute Enum.any?(
               saved_msgs,
               &(&1.role == "assistant" and String.starts_with?(&1.content, "<think>"))
             )

      # preserved
      assert Enum.any?(
               saved_msgs,
               fn
                 %{content: c} = m when is_system_msg?(m) ->
                   c == "Your name is Eldon the Echo."

                 _ ->
                   false
               end
             )

      assert Enum.any?(saved_msgs, fn
               %{content: c} = m when is_system_msg?(m) ->
                 String.starts_with?(c, "Summary of conversation and research thus far:")

               _ ->
                 false
             end)

      # kept
      assert Enum.any?(saved_msgs, &(&1.role == "user" and &1.content == "hello"))
      assert Enum.any?(saved_msgs, &(&1.role == "assistant" and &1.content == "visible answer"))
    end
  end
end

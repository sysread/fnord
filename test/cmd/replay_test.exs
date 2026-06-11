defmodule Cmd.ReplayTest do
  use Fnord.TestCase, async: true
  @moduletag :capture_log

  describe "run/3" do
    setup do
      project = mock_project("test_proj")
      {:ok, project: project}
    end

    test "replays an existing conversation (happy path)" do
      # A real conversation in the per-test store: replay reads it back,
      # rebuilds the completion state, and replays the transcript through UI
      # (swallowed by the test output stub).
      conversation = Store.Project.Conversation.new("abc-123")

      {:ok, _} =
        Store.Project.Conversation.write(conversation, %{
          messages: [AI.Util.user_msg("hi"), AI.Util.assistant_msg("hello there")],
          metadata: %{},
          memories: []
        })

      # The final response prints to stdout from the calling process; capture
      # it both to keep test output clean and to assert the replayed content.
      {stdout, _stderr} =
        capture_all(fn ->
          Process.put(:replay_result, Cmd.Replay.run(%{conversation: "abc-123"}, [], []))
        end)

      result = Process.delete(:replay_result)

      # The happy path returns the completion state rebuilt from the
      # conversation we wrote (plus the loop's prepended agent-name message),
      # and the assistant's final response is replayed to stdout.
      assert %AI.Completion{} = result
      assert Enum.any?(result.messages, &(&1.content == "hi"))
      assert Enum.any?(result.messages, &(&1.content == "hello there"))
      assert stdout =~ "hello there"
    end

    test "returns error when conversation does not exist" do
      result = Cmd.Replay.run(%{conversation: "missing"}, [], [])
      assert result == {:error, :conversation_not_found}
    end

    test "returns error tuple when :conversation is missing" do
      result = Cmd.Replay.run(%{}, [], [])
      assert result == {:error, :missing_conversation}
    end
  end
end

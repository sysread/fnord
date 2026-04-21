defmodule Cmd.ReplayTest do
  use Fnord.TestCase
  @moduletag :capture_log

  describe "run/3" do
    setup do
      mock_project("test_proj")
      :ok
    end

    test "replays an existing conversation (happy path)" do
      :meck.new(Store.Project.Conversation, [:no_link, :passthrough, :non_strict])
      :meck.new(AI.Completion, [:no_link, :passthrough, :non_strict])
      :meck.new(AI.Completion.Output, [:no_link, :passthrough, :non_strict])

      on_exit(fn ->
        :meck.unload(Store.Project.Conversation)
        :meck.unload(AI.Completion)
        :meck.unload(AI.Completion.Output)
      end)

      # Setup: conversation exists
      :meck.expect(Store.Project.Conversation, :exists?, fn _conv -> true end)

      # Stub Completion creation
      fake_conv = Store.Project.Conversation.new("abc-123")
      fake_completion = %AI.Completion{messages: [AI.Util.user_msg("hi")], response: nil}

      :meck.expect(AI.Completion, :new_from_conversation, fn ^fake_conv, opts
                                                             when is_list(opts) ->
        {:ok, fake_completion}
      end)

      :meck.expect(AI.Completion.Output, :replay_conversation_as_output, fn completion ->
        assert completion == fake_completion
        :ok
      end)

      # Execute
      result = Cmd.Replay.run(%{conversation: "abc-123"}, [], [])
      assert result == :ok
    end

    test "returns error when conversation does not exist" do
      :meck.new(Store.Project.Conversation, [:no_link, :passthrough, :non_strict])

      on_exit(fn ->
        :meck.unload(Store.Project.Conversation)
      end)

      :meck.expect(Store.Project.Conversation, :exists?, fn _conv -> false end)

      result = Cmd.Replay.run(%{conversation: "missing"}, [], [])
      assert result == {:error, :conversation_not_found}
    end

    test "returns error tuple when :conversation is missing" do
      result = Cmd.Replay.run(%{}, [], [])
      assert result == {:error, :missing_conversation}
    end
  end
end

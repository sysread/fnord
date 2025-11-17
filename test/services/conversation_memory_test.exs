defmodule Services.ConversationMemoryTest do
  use Fnord.TestCase, async: false

  setup do
    {:ok, project: mock_project("test-conv-memory")}
  end

  describe "memory state tracking" do
    test "initializes with empty memory state" do
      {:ok, pid} = Services.Conversation.start_link()

      # Save conversation first
      {:ok, conversation} = Services.Conversation.save(pid)
      {:ok, _ts, _msgs, metadata} = Store.Project.Conversation.read(conversation)

      # Initial state should be empty (no user/assistant messages yet)
      memory_state = Map.get(metadata, "memory_state", %{})
      assert memory_state == %{}
    end

    test "accumulates tokens from user messages" do
      {:ok, pid} = Services.Conversation.start_link()

      Services.Conversation.append_msg(AI.Util.user_msg("Hello world"), pid)
      Services.Conversation.append_msg(AI.Util.user_msg("Testing example"), pid)

      # Save to persist metadata
      {:ok, conversation} = Services.Conversation.save(pid)
      {:ok, _ts, _msgs, metadata} = Store.Project.Conversation.read(conversation)

      memory_state = metadata["memory_state"]
      accumulated = memory_state["accumulated_tokens"]

      # Should have stemmed tokens
      assert Map.has_key?(accumulated, "hello")
      assert Map.has_key?(accumulated, "world")
      assert Map.has_key?(accumulated, "test")
      assert Map.has_key?(accumulated, "exampl")
    end

    test "filters out system messages, only tracks user/assistant" do
      {:ok, pid} = Services.Conversation.start_link()

      # System messages should be filtered out
      Services.Conversation.append_msg(
        AI.Util.system_msg("System message with special words"),
        pid
      )

      Services.Conversation.append_msg(AI.Util.user_msg("User message"), pid)
      Services.Conversation.append_msg(AI.Util.assistant_msg("Assistant response"), pid)

      {:ok, conversation} = Services.Conversation.save(pid)
      {:ok, _ts, _msgs, metadata} = Store.Project.Conversation.read(conversation)

      memory_state = metadata["memory_state"]
      accumulated = memory_state["accumulated_tokens"]

      # Should have tokens from user and assistant messages
      assert Map.has_key?(accumulated, "user")
      assert Map.has_key?(accumulated, "messag")
      assert Map.has_key?(accumulated, "assist")
      assert Map.has_key?(accumulated, "respons")

      # Should NOT have tokens from system message
      refute Map.has_key?(accumulated, "special")
    end

    test "incremental accumulation on multiple appends" do
      {:ok, pid} = Services.Conversation.start_link()

      Services.Conversation.append_msg(AI.Util.user_msg("cat cat"), pid)
      {:ok, conversation} = Services.Conversation.save(pid)
      {:ok, _ts, _msgs, metadata1} = Store.Project.Conversation.read(conversation)

      accumulated1 = metadata1["memory_state"]["accumulated_tokens"]
      assert accumulated1["cat"] == 2

      # Load conversation and append more
      {:ok, pid2} = Services.Conversation.start_link(conversation.id)
      Services.Conversation.append_msg(AI.Util.user_msg("cat dog"), pid2)
      {:ok, conversation2} = Services.Conversation.save(pid2)
      {:ok, _ts, _msgs, metadata2} = Store.Project.Conversation.read(conversation2)

      accumulated2 = metadata2["memory_state"]["accumulated_tokens"]
      # 2 + 1
      assert accumulated2["cat"] == 3
      assert accumulated2["dog"] == 1
    end

    test "tracks last_processed_index" do
      {:ok, pid} = Services.Conversation.start_link()

      Services.Conversation.append_msg(AI.Util.user_msg("First"), pid)
      Services.Conversation.append_msg(AI.Util.assistant_msg("Response"), pid)
      Services.Conversation.append_msg(AI.Util.user_msg("Second"), pid)

      {:ok, conversation} = Services.Conversation.save(pid)
      {:ok, _ts, msgs, metadata} = Store.Project.Conversation.read(conversation)

      memory_state = metadata["memory_state"]
      assert memory_state["last_processed_index"] == length(msgs) - 1
    end

    test "tracks total_tokens" do
      {:ok, pid} = Services.Conversation.start_link()

      Services.Conversation.append_msg(AI.Util.user_msg("one two three"), pid)

      {:ok, conversation} = Services.Conversation.save(pid)
      {:ok, _ts, _msgs, metadata} = Store.Project.Conversation.read(conversation)

      memory_state = metadata["memory_state"]
      total = memory_state["total_tokens"]

      # Should be sum of all frequencies (one, two, three = 3 tokens, 1 each)
      assert total == 3
    end

    test "trims to top K tokens to prevent bloat" do
      {:ok, pid} = Services.Conversation.start_link()

      # Create message with many unique tokens
      many_words = Enum.map(1..6000, &"word#{&1}") |> Enum.join(" ")
      Services.Conversation.append_msg(AI.Util.user_msg(many_words), pid)

      {:ok, conversation} = Services.Conversation.save(pid)
      {:ok, _ts, _msgs, metadata} = Store.Project.Conversation.read(conversation)

      memory_state = metadata["memory_state"]
      accumulated = memory_state["accumulated_tokens"]

      # Should be trimmed to top 5000
      assert map_size(accumulated) <= 5000
    end

    test "handles empty messages gracefully" do
      {:ok, pid} = Services.Conversation.start_link()

      Services.Conversation.append_msg(AI.Util.user_msg(""), pid)

      {:ok, conversation} = Services.Conversation.save(pid)
      {:ok, _ts, _msgs, metadata} = Store.Project.Conversation.read(conversation)

      # Should not crash, just have minimal state
      memory_state = metadata["memory_state"]
      assert is_map(memory_state)
    end
  end
end

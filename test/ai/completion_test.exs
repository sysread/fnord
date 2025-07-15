defmodule AI.CompletionTest do
  use Fnord.TestCase

  setup do: set_config(quiet: true)

  setup do
    :meck.new(AI.CompletionAPI, [:no_link, :passthrough, :non_strict])
    on_exit(fn -> :meck.unload(AI.CompletionAPI) end)
    :ok
  end

  describe "new/1" do
    test "creates completion state with minimal valid opts" do
      opts = [
        model: "test-model",
        messages: [%{role: "user", content: "yo"}]
      ]

      assert {:ok, state} = AI.Completion.new(opts)
      assert state.model == "test-model"
      assert state.messages == [%{role: "user", content: "yo"}]
      # Defaults
      assert state.log_msgs == false
      assert state.replay_conversation == true
      assert is_list(state.specs)
    end

    test "returns error when :model is missing" do
      opts = [
        messages: [%{role: "user", content: "yo"}]
      ]

      assert :error = AI.Completion.new(opts)
    end

    test "returns error when :messages is missing" do
      opts = [
        model: "test-model"
      ]

      assert :error = AI.Completion.new(opts)
    end

    test "parses optional toolbox and toggles options" do
      my_toolbox = %{}

      opts = [
        model: "x",
        messages: [],
        toolbox: my_toolbox,
        log_msgs: true,
        replay_conversation: false,
        archive_notes: true
      ]

      assert {:ok, state} = AI.Completion.new(opts)
      assert state.toolbox == AI.Tools.build_toolbox(my_toolbox)
      assert state.log_msgs == true
      assert state.replay_conversation == false
      assert state.archive_notes == true
    end
  end

  describe "new_from_conversation/2" do
    test "returns error if conversation does not exist" do
      conv = %{id: "fake-conv-id"}
      :meck.expect(Store.Project.Conversation, :exists?, fn ^conv -> false end)

      assert {:error, :conversation_not_found} =
               AI.Completion.new_from_conversation(conv, model: "mymodel")
    end

    test "returns error if opts missing :model" do
      conv = %{id: "existing-conv"}
      :meck.expect(Store.Project.Conversation, :exists?, fn ^conv -> true end)

      :meck.expect(Store.Project.Conversation, :read, fn ^conv ->
        {:ok, 12345, [%{role: "user", content: "some"}]}
      end)

      assert :error = AI.Completion.new_from_conversation(conv, [])
    end

    test "returns ok state if valid conversation and opts" do
      conv = %{id: "good-conv"}
      :meck.expect(Store.Project.Conversation, :exists?, fn ^conv -> true end)
      messages = [%{role: "user", content: "hello"}, %{role: "assistant", content: "world"}]
      :meck.expect(Store.Project.Conversation, :read, fn ^conv -> {:ok, 888, messages} end)
      opts = [model: "good-model"]
      assert {:ok, state} = AI.Completion.new_from_conversation(conv, opts)
      assert state.model == "good-model"
      assert state.messages == messages
    end
  end

describe "get/1" do
  test "Completion.get/1 surfaces API error response to user" do
    :meck.expect(AI.CompletionAPI, :get, fn _model, _msgs, _specs ->
      {:error, %{http_status: 500, code: "server_error", message: "backend exploded"}}
    end)

    user_msg = %{role: "user", content: "trigger error"}

    assert {:error, state} =
             AI.Completion.get(
               model: AI.Model.new("dummy", 0),
               messages: [user_msg],
               toolbox: %{}
             )

    assert state.response =~ "HTTP Status: 500"
    assert state.response =~ "Error code: server_error"
    assert state.response =~ "backend exploded"
  end

  test "Completion.get/1 surfaces rate limit error response and can print it" do
    :meck.expect(AI.CompletionAPI, :get, fn _model, _msgs, _specs ->
      {:error, %{http_status: 429, code: "rate_limit", message: "Rate limit exceeded"}}
    end)

    user_msg = %{role: "user", content: "trigger error"}

    assert {:error, state} =
             AI.Completion.get(
               model: AI.Model.new("dummy", 0),
               messages: [user_msg],
               toolbox: %{}
             )

    output = ExUnit.CaptureIO.capture_io(fn -> IO.puts(state.response) end)

    assert output =~ "429"
    assert output =~ "rate_limit"
    assert output =~ "Rate limit exceeded"
  end
end
  describe "tools_used/1" do
    test "returns empty map if no messages" do
      assert %{} = AI.Completion.tools_used(%AI.Completion{messages: []})
    end

    test "returns tool call counts for a single message with multiple tools" do
      messages = [
        %{
          tool_calls: [
            %{function: %{name: "foo"}},
            %{function: %{name: "bar"}},
            %{function: %{name: "foo"}}
          ]
        }
      ]

      assert %{"foo" => 2, "bar" => 1} =
               AI.Completion.tools_used(%AI.Completion{messages: messages})
    end

    test "returns tool call counts across multiple messages" do
      messages = [
        %{tool_calls: [%{function: %{name: "foo"}}]},
        %{},
        %{tool_calls: [%{function: %{name: "foo"}}, %{function: %{name: "bar"}}]}
      ]

      assert %{"foo" => 2, "bar" => 1} =
               AI.Completion.tools_used(%AI.Completion{messages: messages})
    end

    test "ignores messages with no tool_calls key or non-matching entries" do
      messages = [
        %{},
        %{unexpected: 123, content: "skip me"},
        %{tool_calls: []}
      ]

      assert %{} = AI.Completion.tools_used(%AI.Completion{messages: messages})
    end
  end

  describe "toolbox integration" do
    defmodule TestTool do
      @behaviour AI.Tools

      @impl AI.Tools
      def async?, do: true

      @impl AI.Tools
      def spec do
        %{
          type: "function",
          function: %{
            name: "test_tool",
            parameters: %{type: "object", required: [], properties: %{}}
          }
        }
      end

      @impl AI.Tools
      def is_available?, do: true

      @impl AI.Tools
      def read_args(args), do: {:ok, args}

      @impl AI.Tools
      def call(_args), do: {:ok, "tool_result"}

      @impl AI.Tools
      def ui_note_on_request(_args), do: {"Calling test_tool", "Invoking test_tool"}

      @impl AI.Tools
      def ui_note_on_result(_args, _result), do: {"Called test_tool", "test_tool completed"}
    end

    defmodule TestToolSync do
      @behaviour AI.Tools

      @impl AI.Tools
      def async?, do: false

      @impl AI.Tools
      def spec do
        %{
          type: "function",
          function: %{
            name: "test_tool_sync",
            parameters: %{type: "object", required: [], properties: %{}}
          }
        }
      end

      @impl AI.Tools
      def is_available?, do: true

      @impl AI.Tools
      def read_args(args), do: {:ok, args}

      @impl AI.Tools
      def call(_args), do: {:ok, "tool_result_sync"}

      @impl AI.Tools
      def ui_note_on_request(_args) do
        {"Calling test_tool_sync", "Invoking test_tool_sync"}
      end

      @impl AI.Tools
      def ui_note_on_result(_args, _result) do
        {"Called test_tool_sync", "test_tool completed_sync"}
      end
    end

    test "Completion.get/1 invokes local tools from toolbox" do
      # Stub CompletionAPI.get to return a tool call, then a final assistant message
      :meck.expect(AI.CompletionAPI, :get, fn _model, msgs, _specs ->
        tool_calls_sent? = Enum.any?(msgs, fn msg -> Map.has_key?(msg, :tool_calls) end)

        if tool_calls_sent? do
          {:ok, :msg, "final response", 0}
        else
          tool_call = %{id: 1, function: %{name: "test_tool", arguments: "{}"}}
          {:ok, :tool, [tool_call]}
        end
      end)

      user_msg = %{role: "user", content: "run test_tool"}

      assert {:ok, state} =
               AI.Completion.get(
                 model: AI.Model.new("dummy", 0),
                 messages: [user_msg],
                 toolbox: %{"test_tool" => TestTool}
               )

      # Assert the tool request message is present
      assert Enum.any?(state.messages, fn msg ->
               msg.role == "assistant" and msg.content == nil and Map.has_key?(msg, :tool_calls)
             end)

      # Assert the tool response message includes our tool result
      assert Enum.any?(state.messages, fn msg ->
               msg.role == "tool" and msg.name == "test_tool" and msg.content =~ "tool_result"
             end)

      # Assert the final assistant message is included
      assert List.last(state.messages).role == "assistant"
      assert List.last(state.messages).content == "final response"
    end

    test "Tool calls invocation respects async?/0" do
      # Stub CompletionAPI.get to return a tool call, then a final assistant message
      :meck.expect(AI.CompletionAPI, :get, fn _model, msgs, _specs ->
        tool_calls_sent? = Enum.any?(msgs, fn msg -> Map.has_key?(msg, :tool_calls) end)

        if tool_calls_sent? do
          {:ok, :msg, "final response", 0}
        else
          {:ok, :tool,
           [
             %{id: 1, function: %{name: "test_tool_sync", arguments: "{}"}},
             %{id: 2, function: %{name: "test_tool", arguments: "{}"}},
             %{id: 3, function: %{name: "test_tool_sync", arguments: "{}"}}
           ]}
        end
      end)

      user_msg = %{role: "user", content: "do stuff, por favor"}

      assert {:ok, state} =
               AI.Completion.get(
                 model: AI.Model.new("dummy", 0),
                 messages: [user_msg],
                 toolbox: %{"test_tool" => TestTool}
               )

      tool_call_ids_in_order =
        state.messages
        |> Enum.filter(&(&1.role == "tool"))
        |> Enum.map(& &1.tool_call_id)

      # #2 should be shuffled ahead because it's async. #1 and #3 are sync and
      # should be in order and at the end.
      assert tool_call_ids_in_order == [2, 1, 3]
    end

    test "Completion.get/1 handles unknown tool requests gracefully" do
      :meck.expect(AI.CompletionAPI, :get, fn _model, msgs, _specs ->
        tool_calls_sent? = Enum.any?(msgs, fn msg -> Map.has_key?(msg, :tool_calls) end)

        if tool_calls_sent? do
          {:ok, :msg, "final assistant response", 0}
        else
          tool_call = %{id: 1, function: %{name: "ghost_tool", arguments: "{}"}}
          {:ok, :tool, [tool_call]}
        end
      end)

      user_msg = %{role: "user", content: "please use ghost_tool"}

      assert {:ok, state} =
               AI.Completion.get(
                 model: AI.Model.new("dummy", 0),
                 messages: [user_msg],
                 toolbox: %{"test_tool" => TestTool}
               )

      assert Enum.any?(state.messages, fn msg ->
               msg.role == "tool" and msg.name == "ghost_tool" and
                 (msg.content =~ "not found" or msg.content =~ "unknown tool")
             end)

      assert List.last(state.messages).role == "assistant"
      assert List.last(state.messages).content == "final assistant response"
    end
  end
end

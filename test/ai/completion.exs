defmodule AI.Completion do
  use Fnord.TestCase

  alias AI.Completion
  alias AI.Model

  setup do: set_config(quiet: true)

  describe "get/1" do
    test "Completion.get/1 surfaces API error response to user" do
      :meck.new(AI.CompletionAPI, [:non_strict])

      :meck.expect(AI.CompletionAPI, :get, fn _model, _msgs, _specs ->
        {:error, %{http_status: 500, code: "server_error", message: "backend exploded"}}
      end)

      user_msg = %{role: "user", content: "trigger error"}

      opts = [
        model: Model.new("dummy", 0),
        messages: [user_msg],
        toolbox: %{}
      ]

      assert {:error, state} = Completion.get(opts)

      assert state.response =~ "HTTP Status: 500"
      assert state.response =~ "Error code: server_error"
      assert state.response =~ "backend exploded"

      :meck.unload(AI.CompletionAPI)
    end
  end

  describe "toolbox integration" do
    defmodule TestTool do
      @behaviour AI.Tools

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

    test "Completion.get/1 invokes local tools from toolbox" do
      :meck.new(AI.CompletionAPI, [:non_strict])
      # Stub CompletionAPI.get to return a tool call, then a final assistant message
      :meck.expect(AI.CompletionAPI, :get, fn _model, msgs, _specs ->
        if Enum.any?(msgs, fn msg ->
             msg.role == "assistant" and msg.content == nil and Map.has_key?(msg, :tool_calls)
           end) do
          {:ok, :msg, "final response", 0}
        else
          tool_call = %{id: 1, function: %{name: "test_tool", arguments: "{}"}}
          {:ok, :tool, [tool_call]}
        end
      end)

      user_msg = %{role: "user", content: "run test_tool"}

      opts = [
        model: Model.new("dummy", 0),
        messages: [user_msg],
        toolbox: %{"test_tool" => TestTool}
      ]

      assert {:ok, state} = Completion.get(opts)

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
      :meck.unload(AI.CompletionAPI)
    end
  end
end

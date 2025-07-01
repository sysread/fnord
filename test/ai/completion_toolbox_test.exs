defmodule AI.CompletionToolboxTest do
  use ExUnit.Case, async: false

  alias AI.Completion
  alias AI.Model

  describe "toolbox integration" do
    setup do
      :meck.new(AI.ChatCompletion, [:non_strict])
      on_exit(fn -> :meck.unload(AI.ChatCompletion) end)
      :ok
    end

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
      # Stub ChatCompletion.get to return a tool call, then a final assistant message
      :meck.expect(AI.ChatCompletion, :get, fn _model, msgs, _specs ->
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
    end
  end
end

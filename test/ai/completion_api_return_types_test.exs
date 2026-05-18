defmodule AI.CompletionAPITest do
  use ExUnit.Case
  alias AI.Model

  # The mock stub runs inside AI.CompletionAPI.get/6, which has a catch-all
  # rescue that swallows any exception (including ExUnit.AssertionError).
  # Anything we want to assert about the outgoing payload has to leave the
  # stub before it can be re-raised in the test process. We send the captured
  # payload to the test pid and assert against it after the call returns.

  setup do
    :ok = :meck.new(AI.Endpoint, [:no_link, :passthrough])
    on_exit(fn -> :meck.unload(AI.Endpoint) end)
    :ok
  end

  describe "Responses API wire format" do
    test "request payload uses input: not messages:, with typed user message item" do
      test_pid = self()

      :meck.expect(AI.Endpoint, :post_json, fn AI.CompletionAPI, _headers, payload ->
        send(test_pid, {:payload, payload})
        {:ok, %{body: %{"output" => [], "usage" => %{"total_tokens" => 0}}}}
      end)

      model = %Model{model: "test-model", context: 0, reasoning: :medium}
      AI.CompletionAPI.get(model, [%{role: "user", content: "hello"}], nil, nil, false)

      assert_receive {:payload, payload}
      refute Map.has_key?(payload, :messages)
      assert Map.has_key?(payload, :input)
      assert payload.store == false

      [item] = payload.input
      assert item.type == "message"
      assert item.role == "user"
      assert item.content == [%{type: "input_text", text: "hello"}]
    end

    test "verbosity is routed under text.verbosity (not a top-level field)" do
      test_pid = self()

      :meck.expect(AI.Endpoint, :post_json, fn AI.CompletionAPI, _headers, payload ->
        send(test_pid, {:payload, payload})
        {:ok, %{body: %{"output" => [], "usage" => %{"total_tokens" => 0}}}}
      end)

      model = %Model{model: "test-model", context: 0, reasoning: :medium}
      AI.CompletionAPI.get(model, [], nil, nil, false, "high")

      assert_receive {:payload, payload}
      refute Map.has_key?(payload, :verbosity)
      assert payload.text.verbosity == "high"
    end

    test "verbosity nil is omitted from text" do
      test_pid = self()

      :meck.expect(AI.Endpoint, :post_json, fn AI.CompletionAPI, _headers, payload ->
        send(test_pid, {:payload, payload})
        {:ok, %{body: %{"output" => [], "usage" => %{"total_tokens" => 0}}}}
      end)

      model = %Model{model: "test-model", context: 0, reasoning: :medium}
      AI.CompletionAPI.get(model, [], nil, nil, false, nil)

      assert_receive {:payload, payload}
      refute Map.has_key?(payload.text, :verbosity)
    end

    test "response_format is routed under text.format" do
      test_pid = self()

      :meck.expect(AI.Endpoint, :post_json, fn AI.CompletionAPI, _headers, payload ->
        send(test_pid, {:payload, payload})
        {:ok, %{body: %{"output" => [], "usage" => %{"total_tokens" => 0}}}}
      end)

      model = %Model{model: "test-model", context: 0, reasoning: :medium}
      AI.CompletionAPI.get(model, [], nil, %{type: "json_object"}, false)

      assert_receive {:payload, payload}
      refute Map.has_key?(payload, :response_format)
      assert payload.text.format == %{type: "json_object"}
    end

    test "reasoning is routed under reasoning.effort (not reasoning_effort)" do
      test_pid = self()

      :meck.expect(AI.Endpoint, :post_json, fn AI.CompletionAPI, _headers, payload ->
        send(test_pid, {:payload, payload})
        {:ok, %{body: %{"output" => [], "usage" => %{"total_tokens" => 0}}}}
      end)

      model = %Model{model: "test-model", context: 0, reasoning: :high}
      AI.CompletionAPI.get(model, [], nil, nil, false)

      assert_receive {:payload, payload}
      refute Map.has_key?(payload, :reasoning_effort)
      assert payload.reasoning == %{effort: "high"}
    end

    test "web search becomes a tools entry, not a top-level web_search_options" do
      test_pid = self()

      :meck.expect(AI.Endpoint, :post_json, fn AI.CompletionAPI, _headers, payload ->
        send(test_pid, {:payload, payload})
        {:ok, %{body: %{"output" => [], "usage" => %{"total_tokens" => 0}}}}
      end)

      model = %Model{model: "test-model", context: 0, reasoning: :medium}
      AI.CompletionAPI.get(model, [], nil, nil, true)

      assert_receive {:payload, payload}
      refute Map.has_key?(payload, :web_search_options)
      assert %{type: "web_search_preview"} in payload.tools
    end

    test "assistant tool-call messages fan out to function_call input items" do
      test_pid = self()

      :meck.expect(AI.Endpoint, :post_json, fn AI.CompletionAPI, _headers, payload ->
        send(test_pid, {:payload, payload})
        {:ok, %{body: %{"output" => [], "usage" => %{"total_tokens" => 0}}}}
      end)

      tool_call_msg = %{
        role: "assistant",
        content: nil,
        tool_calls: [
          %{id: "c1", type: "function", function: %{name: "search", arguments: "{\"q\":\"x\"}"}}
        ]
      }

      model = %Model{model: "test-model", context: 0, reasoning: :medium}
      AI.CompletionAPI.get(model, [tool_call_msg], nil, nil, false)

      assert_receive {:payload, payload}

      assert [%{type: "function_call", call_id: "c1", name: "search", arguments: "{\"q\":\"x\"}"}] =
               payload.input
    end

    test "tool-response messages become function_call_output items" do
      test_pid = self()

      :meck.expect(AI.Endpoint, :post_json, fn AI.CompletionAPI, _headers, payload ->
        send(test_pid, {:payload, payload})
        {:ok, %{body: %{"output" => [], "usage" => %{"total_tokens" => 0}}}}
      end)

      tool_resp_msg = %{role: "tool", tool_call_id: "c1", name: "search", content: "result"}

      model = %Model{model: "test-model", context: 0, reasoning: :medium}
      AI.CompletionAPI.get(model, [tool_resp_msg], nil, nil, false)

      assert_receive {:payload, payload}
      assert [%{type: "function_call_output", call_id: "c1", output: "result"}] = payload.input
    end
  end

  describe "Responses API response parsing" do
    test "an output of message items returns {:ok, :msg, text, tokens}" do
      :meck.expect(AI.Endpoint, :post_json, fn AI.CompletionAPI, _h, _p ->
        {:ok,
         %{
           body: %{
             "output" => [
               %{
                 "type" => "message",
                 "content" => [%{"type" => "output_text", "text" => "hello there"}]
               }
             ],
             "usage" => %{"total_tokens" => 42}
           }
         }}
      end)

      model = %Model{model: "test-model", context: 0, reasoning: :medium}
      assert {:ok, :msg, "hello there", 42} = AI.CompletionAPI.get(model, [], nil, nil, false)
    end

    test "an output of function_call items returns {:ok, :tool, [calls]} with id translated from call_id" do
      :meck.expect(AI.Endpoint, :post_json, fn AI.CompletionAPI, _h, _p ->
        {:ok,
         %{
           body: %{
             "output" => [
               %{
                 "type" => "function_call",
                 "call_id" => "c1",
                 "name" => "search",
                 "arguments" => "{\"q\":\"x\"}"
               }
             ],
             "usage" => %{"total_tokens" => 7}
           }
         }}
      end)

      model = %Model{model: "test-model", context: 0, reasoning: :medium}

      assert {:ok, :tool, [%{id: "c1", function: %{name: "search", arguments: "{\"q\":\"x\"}"}}]} =
               AI.CompletionAPI.get(model, [], nil, nil, false)
    end

    test "reasoning items in the output are silently skipped" do
      :meck.expect(AI.Endpoint, :post_json, fn AI.CompletionAPI, _h, _p ->
        {:ok,
         %{
           body: %{
             "output" => [
               %{"type" => "reasoning", "id" => "r1", "summary" => []},
               %{
                 "type" => "message",
                 "content" => [%{"type" => "output_text", "text" => "ok"}]
               }
             ],
             "usage" => %{"total_tokens" => 1}
           }
         }}
      end)

      model = %Model{model: "test-model", context: 0, reasoning: :medium}
      assert {:ok, :msg, "ok", 1} = AI.CompletionAPI.get(model, [], nil, nil, false)
    end

    test "multi-part message content joins all output_text segments" do
      :meck.expect(AI.Endpoint, :post_json, fn AI.CompletionAPI, _h, _p ->
        {:ok,
         %{
           body: %{
             "output" => [
               %{
                 "type" => "message",
                 "content" => [
                   %{"type" => "output_text", "text" => "part one "},
                   %{"type" => "output_text", "text" => "part two"}
                 ]
               }
             ],
             "usage" => %{"total_tokens" => 5}
           }
         }}
      end)

      model = %Model{model: "test-model", context: 0, reasoning: :medium}
      assert {:ok, :msg, "part one part two", 5} = AI.CompletionAPI.get(model, [], nil, nil, false)
    end
  end

  describe "transport errors" do
    test "maps :closed to {:error, \"Connection closed\"}" do
      :meck.expect(AI.Endpoint, :post_json, fn AI.CompletionAPI, _h, _p ->
        {:transport_error, :closed}
      end)

      model = %Model{model: "test-model", context: 0, reasoning: :medium}
      assert {:error, "Connection closed"} = AI.CompletionAPI.get(model, [], nil, nil, false)
    end
  end
end

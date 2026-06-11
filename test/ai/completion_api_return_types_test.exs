defmodule AI.CompletionAPITest do
  use Fnord.TestCase, async: true
  alias AI.Model

  # These tests exercise AI.CompletionAPI directly (not through impl()), with
  # the transport stubbed at Http.Client. The outgoing payload is captured
  # AFTER JSON encoding, so assertions here are against the literal wire
  # shape the API sees - string keys and all.
  #
  # AI.CompletionAPI.get/6 has a catch-all rescue that swallows any exception
  # (including ExUnit.AssertionError), so nothing may be asserted inside the
  # stub; captured payloads are sent to the test pid and asserted after the
  # call returns.

  defp empty_success do
    {:ok,
     %HTTPoison.Response{
       status_code: 200,
       headers: [],
       body: ~s({"output": [], "usage": {"total_tokens": 0}})
     }}
  end

  defp capture_payload do
    test_pid = self()

    stub(Http.Client.Mock, :post, fn _url, body, _headers, _opts ->
      send(test_pid, {:payload, SafeJson.decode!(body)})
      empty_success()
    end)
  end

  defp respond_with(body_map) do
    stub(Http.Client.Mock, :post, fn _url, _body, _headers, _opts ->
      {:ok, %HTTPoison.Response{status_code: 200, headers: [], body: SafeJson.encode!(body_map)}}
    end)
  end

  describe "Responses API wire format" do
    test "request payload uses input: not messages:, with typed user message item" do
      capture_payload()

      model = %Model{model: "test-model", context: 0, reasoning: :medium}
      AI.CompletionAPI.get(model, [%{role: "user", content: "hello"}], nil, nil, false)

      assert_receive {:payload, payload}
      refute Map.has_key?(payload, "messages")
      assert Map.has_key?(payload, "input")
      assert payload["store"] == false

      [item] = payload["input"]
      assert item["type"] == "message"
      assert item["role"] == "user"
      assert item["content"] == [%{"type" => "input_text", "text" => "hello"}]
    end

    test "verbosity is routed under text.verbosity (not a top-level field)" do
      capture_payload()

      model = %Model{model: "test-model", context: 0, reasoning: :medium}
      AI.CompletionAPI.get(model, [], nil, nil, false, "high")

      assert_receive {:payload, payload}
      refute Map.has_key?(payload, "verbosity")
      assert payload["text"]["verbosity"] == "high"
    end

    test "verbosity nil is omitted from text" do
      capture_payload()

      model = %Model{model: "test-model", context: 0, reasoning: :medium}
      AI.CompletionAPI.get(model, [], nil, nil, false, nil)

      assert_receive {:payload, payload}
      refute Map.has_key?(payload["text"], "verbosity")
    end

    test "response_format is routed under text.format" do
      capture_payload()

      model = %Model{model: "test-model", context: 0, reasoning: :medium}
      AI.CompletionAPI.get(model, [], nil, %{type: "json_object"}, false)

      assert_receive {:payload, payload}
      refute Map.has_key?(payload, "response_format")
      assert payload["text"]["format"] == %{"type" => "json_object"}
    end

    test "chat-completions-style json_schema is flattened for the Responses API" do
      capture_payload()

      model = %Model{model: "test-model", context: 0, reasoning: :medium}

      nested = %{
        type: "json_schema",
        json_schema: %{
          name: "thing",
          description: "a thing",
          strict: true,
          schema: %{type: "object", properties: %{x: %{type: "string"}}}
        }
      }

      AI.CompletionAPI.get(model, [], nil, nested, false)

      assert_receive {:payload, payload}
      format = payload["text"]["format"]
      assert format["type"] == "json_schema"
      assert format["name"] == "thing"
      assert format["description"] == "a thing"
      assert format["strict"] == true
      assert format["schema"]["type"] == "object"
      refute Map.has_key?(format, "json_schema")
    end

    test "already-flat json_schema passes through untouched" do
      capture_payload()

      model = %Model{model: "test-model", context: 0, reasoning: :medium}

      flat = %{
        type: "json_schema",
        name: "thing",
        schema: %{type: "object"}
      }

      AI.CompletionAPI.get(model, [], nil, flat, false)

      assert_receive {:payload, payload}

      assert payload["text"]["format"] == %{
               "type" => "json_schema",
               "name" => "thing",
               "schema" => %{"type" => "object"}
             }
    end

    test "string-keyed nested json_schema (e.g. TOML-loaded skills) is also flattened" do
      capture_payload()

      model = %Model{model: "test-model", context: 0, reasoning: :medium}

      nested = %{
        "type" => "json_schema",
        "json_schema" => %{
          "name" => "thing",
          "schema" => %{"type" => "object"}
        }
      }

      AI.CompletionAPI.get(model, [], nil, nested, false)

      assert_receive {:payload, payload}
      format = payload["text"]["format"]
      assert format["type"] == "json_schema"
      assert format["name"] == "thing"
      assert format["schema"] == %{"type" => "object"}
      refute Map.has_key?(format, "json_schema")
    end

    test "reasoning is routed under reasoning.effort (not reasoning_effort)" do
      capture_payload()

      model = %Model{model: "test-model", context: 0, reasoning: :high}
      AI.CompletionAPI.get(model, [], nil, nil, false)

      assert_receive {:payload, payload}
      refute Map.has_key?(payload, "reasoning_effort")
      assert payload["reasoning"] == %{"effort" => "high"}
    end

    test "web search becomes a tools entry, not a top-level web_search_options" do
      capture_payload()

      model = %Model{model: "test-model", context: 0, reasoning: :medium}
      AI.CompletionAPI.get(model, [], nil, nil, true)

      assert_receive {:payload, payload}
      refute Map.has_key?(payload, "web_search_options")
      assert %{"type" => "web_search"} in payload["tools"]
      # Belt-and-braces: never emit the legacy preview name for new requests.
      refute %{"type" => "web_search_preview"} in payload["tools"]
    end

    test "assistant tool-call messages fan out to function_call input items" do
      capture_payload()

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

      assert [
               %{
                 "type" => "function_call",
                 "call_id" => "c1",
                 "name" => "search",
                 "arguments" => "{\"q\":\"x\"}"
               }
             ] = payload["input"]
    end

    test "tool-response messages become function_call_output items" do
      capture_payload()

      tool_resp_msg = %{role: "tool", tool_call_id: "c1", name: "search", content: "result"}

      model = %Model{model: "test-model", context: 0, reasoning: :medium}
      AI.CompletionAPI.get(model, [tool_resp_msg], nil, nil, false)

      assert_receive {:payload, payload}

      assert [%{"type" => "function_call_output", "call_id" => "c1", "output" => "result"}] =
               payload["input"]
    end
  end

  describe "Responses API response parsing" do
    test "an output of message items returns {:ok, :msg, text, tokens}" do
      respond_with(%{
        "output" => [
          %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => "hello there"}]
          }
        ],
        "usage" => %{"total_tokens" => 42}
      })

      model = %Model{model: "test-model", context: 0, reasoning: :medium}
      assert {:ok, :msg, "hello there", 42} = AI.CompletionAPI.get(model, [], nil, nil, false)
    end

    test "an output of function_call items returns {:ok, :tool, [calls]} with id translated from call_id" do
      respond_with(%{
        "output" => [
          %{
            "type" => "function_call",
            "call_id" => "c1",
            "name" => "search",
            "arguments" => "{\"q\":\"x\"}"
          }
        ],
        "usage" => %{"total_tokens" => 7}
      })

      model = %Model{model: "test-model", context: 0, reasoning: :medium}

      assert {:ok, :tool, [%{id: "c1", function: %{name: "search", arguments: "{\"q\":\"x\"}"}}]} =
               AI.CompletionAPI.get(model, [], nil, nil, false)
    end

    test "reasoning items in the output are silently skipped" do
      respond_with(%{
        "output" => [
          %{"type" => "reasoning", "id" => "r1", "summary" => []},
          %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => "ok"}]
          }
        ],
        "usage" => %{"total_tokens" => 1}
      })

      model = %Model{model: "test-model", context: 0, reasoning: :medium}
      assert {:ok, :msg, "ok", 1} = AI.CompletionAPI.get(model, [], nil, nil, false)
    end

    test "multi-part message content joins all output_text segments" do
      respond_with(%{
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
      })

      model = %Model{model: "test-model", context: 0, reasoning: :medium}

      assert {:ok, :msg, "part one part two", 5} =
               AI.CompletionAPI.get(model, [], nil, nil, false)
    end
  end

  describe "transport errors" do
    test "maps :closed to {:error, \"Connection closed\"}" do
      # :closed is retryable, so the Http and endpoint retry loops both
      # exhaust their budgets (sleeps skipped by TestCase) before the error
      # surfaces; the final mapping is what matters here.
      stub(Http.Client.Mock, :post, fn _url, _body, _headers, _opts ->
        {:error, %HTTPoison.Error{reason: :closed}}
      end)

      model = %Model{model: "test-model", context: 0, reasoning: :medium}
      assert {:error, "Connection closed"} = AI.CompletionAPI.get(model, [], nil, nil, false)
    end
  end
end

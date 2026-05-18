defmodule AI.MessageTest do
  use Fnord.TestCase, async: true

  alias AI.Message
  alias AI.Message.{User, Assistant, System, Reasoning}

  describe "AI.Message.user/1 + AI.Message.User" do
    test "constructs with content as a binary and role: \"user\"" do
      assert %User{role: "user", content: "hello"} = Message.user("hello")
    end

    test "text/1 returns the binary content" do
      assert Message.text(Message.user("hello")) == "hello"
    end

    test "for_transcript/1 emits a USER block" do
      assert Message.for_transcript(Message.user("the question")) == "# USER:\nthe question"
    end

    test "to_map/1 wraps the binary in a Responses input_text part for the wire" do
      assert Message.to_map(Message.user("hi")) == %{
               type: "message",
               role: "user",
               content: [%{type: "input_text", text: "hi"}]
             }
    end

    test "round-trips through to_map/1 + from_map/1" do
      original = Message.user("round trip")
      {:ok, hydrated} = Message.from_map(Message.to_map(original))
      assert hydrated == original
    end

    test "from_map/1 tolerates legacy chat-completions binary content" do
      {:ok, msg} = Message.from_map(%{type: "message", role: "user", content: "legacy"})
      assert msg.content == "legacy"
    end

    test "from_map/1 tolerates string-keyed (on-disk) shape" do
      {:ok, msg} =
        Message.from_map(%{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => "from disk"}]
        })

      assert msg.content == "from disk"
    end

    test "from_map/1 joins multi-part wire content into one binary" do
      {:ok, msg} =
        Message.from_map(%{
          type: "message",
          role: "user",
          content: [
            %{type: "input_text", text: "a"},
            %{type: "input_text", text: "b"}
          ]
        })

      assert msg.content == "ab"
    end
  end

  describe "AI.Message.assistant/1 + AI.Message.Assistant" do
    test "constructs with content as a binary and role: \"assistant\"" do
      assert %Assistant{role: "assistant", content: "reply"} = Message.assistant("reply")
    end

    test "for_transcript/1 emits an ASSISTANT block, nil for empty content" do
      assert Message.for_transcript(Message.assistant("ok")) == "# ASSISTANT:\nok"
      assert Message.for_transcript(Message.assistant("")) == nil
    end

    test "to_map/1 wraps the binary in a Responses output_text part for the wire" do
      assert Message.to_map(Message.assistant("yo")) == %{
               type: "message",
               role: "assistant",
               content: [%{type: "output_text", text: "yo"}]
             }
    end

    test "round-trips through to_map/1 + from_map/1" do
      original = Message.assistant("rt")
      {:ok, hydrated} = Message.from_map(Message.to_map(original))
      assert hydrated == original
    end
  end

  describe "AI.Message.system/2 + AI.Message.System" do
    test "defaults role to \"developer\" with content as a binary" do
      assert %System{role: "developer", content: "be helpful"} = Message.system("be helpful")
    end

    test "honors a role override (e.g. for Venice's \"system\" convention)" do
      assert %System{role: "system"} = Message.system("be helpful", role: "system")
    end

    test "for_transcript/1 returns nil - system msgs are excluded from transcripts" do
      assert Message.for_transcript(Message.system("instructions")) == nil
    end

    test "to_map/1 emits the configured role on the wire" do
      assert Message.to_map(Message.system("x", role: "system")) == %{
               type: "message",
               role: "system",
               content: [%{type: "input_text", text: "x"}]
             }
    end

    test "round-trips developer- and system-role messages distinctly" do
      dev = Message.system("dev")
      sys = Message.system("sys", role: "system")
      {:ok, dev_rt} = Message.from_map(Message.to_map(dev))
      {:ok, sys_rt} = Message.from_map(Message.to_map(sys))
      assert dev_rt == dev
      assert sys_rt == sys
    end
  end

  describe "AI.Message.function_call/3 + AI.Message.FunctionCall" do
    test "arguments must be a binary - rejects decoded maps at construction" do
      assert_raise FunctionClauseError, fn ->
        Message.function_call("c1", "tool", %{"a" => 1})
      end
    end

    test "text/1 is nil; for_transcript/1 renders a TOOL CALL block" do
      msg = Message.function_call("c1", "search", "{\"q\":\"foo\"}")
      assert Message.text(msg) == nil
      assert Message.for_transcript(msg) =~ "# TOOL CALL: search"
      assert Message.for_transcript(msg) =~ "{\"q\":\"foo\"}"
    end

    test "to_map/1 emits the Responses function_call wire shape" do
      msg = Message.function_call("c1", "search", "{}")

      assert Message.to_map(msg) == %{
               type: "function_call",
               call_id: "c1",
               name: "search",
               arguments: "{}"
             }
    end

    test "round-trips through to_map/1 + from_map/1" do
      original = Message.function_call("c1", "search", "{\"q\":\"x\"}")
      {:ok, hydrated} = Message.from_map(Message.to_map(original))
      assert hydrated == original
    end

    test "from_map/1 accepts legacy `id` in place of `call_id`" do
      {:ok, msg} =
        Message.from_map(%{
          type: "function_call",
          id: "legacy-id",
          name: "search",
          arguments: "{}"
        })

      assert msg.call_id == "legacy-id"
    end

    # Defensive coercion for v0 files that decoded arguments to a map. We
    # never want a decoded map to live on disk; re-encode on read.
    test "from_map/1 re-encodes a map-valued arguments back to a JSON string" do
      {:ok, msg} =
        Message.from_map(%{
          type: "function_call",
          call_id: "c1",
          name: "search",
          arguments: %{"q" => "foo"}
        })

      assert is_binary(msg.arguments)
      assert msg.arguments =~ "foo"
    end
  end

  describe "AI.Message.function_call_output/2 + AI.Message.FunctionCallOutput" do
    test "text/1 returns the output verbatim" do
      msg = Message.function_call_output("c1", "the answer")
      assert Message.text(msg) == "the answer"
    end

    test "for_transcript/1 emits a TOOL OUTPUT block" do
      assert Message.for_transcript(Message.function_call_output("c1", "x")) =~ "# TOOL OUTPUT"
    end

    test "to_map/1 emits the Responses function_call_output wire shape" do
      assert Message.to_map(Message.function_call_output("c1", "ok")) == %{
               type: "function_call_output",
               call_id: "c1",
               output: "ok"
             }
    end

    test "round-trips through to_map/1 + from_map/1" do
      original = Message.function_call_output("c1", "result")
      {:ok, hydrated} = Message.from_map(Message.to_map(original))
      assert hydrated == original
    end

    test "from_map/1 accepts legacy `tool_call_id` and `content` field names" do
      {:ok, msg} =
        Message.from_map(%{
          type: "function_call_output",
          tool_call_id: "legacy",
          content: "stuff"
        })

      assert msg.call_id == "legacy"
      assert msg.output == "stuff"
    end

    test "non-binary output is stringified via inspect" do
      msg = Message.function_call_output("c1", %{a: 1})
      assert msg.output =~ "a:"
      assert msg.output =~ "1"
    end
  end

  describe "AI.Message.reasoning/1 + AI.Message.Reasoning" do
    test "stores and round-trips the raw map verbatim" do
      raw = %{type: "reasoning", id: "r1", summary: [%{text: "thinking..."}]}
      msg = Message.reasoning(raw)
      assert Message.to_map(msg) == raw
    end

    test "ensures type: \"reasoning\" is set when not present" do
      msg = Message.reasoning(%{id: "r1"})
      assert Message.to_map(msg).type == "reasoning"
    end

    test "text/1 and for_transcript/1 both return nil - opaque payload" do
      msg = Message.reasoning(%{type: "reasoning", id: "r1"})
      assert Message.text(msg) == nil
      assert Message.for_transcript(msg) == nil
    end

    test "from_map/1 round-trips" do
      raw = %{type: "reasoning", id: "r1", encrypted_content: "abc"}
      {:ok, hydrated} = Message.from_map(raw)
      assert Reasoning.to_map(hydrated) == raw
    end
  end

  describe "AI.Message.from_map/1 dispatch" do
    test "returns an error for unknown shapes" do
      assert {:error, {:unknown_message_shape, _}} = Message.from_map(%{type: "what"})
    end

    test "from_map!/1 raises on unknown shapes" do
      assert_raise ArgumentError, ~r/unknown_message_shape/, fn ->
        Message.from_map!(%{type: "what"})
      end
    end

    test "dispatches developer-role messages to System" do
      {:ok, msg} =
        Message.from_map(%{
          type: "message",
          role: "developer",
          content: [%{type: "input_text", text: "go"}]
        })

      assert %System{role: "developer"} = msg
    end

    test "dispatches system-role messages to System (preserving the role)" do
      {:ok, msg} =
        Message.from_map(%{
          type: "message",
          role: "system",
          content: [%{type: "input_text", text: "go"}]
        })

      assert %System{role: "system"} = msg
    end
  end

  describe "raw-map compatibility (drop-in pattern matching)" do
    # Phase 2b's central premise: AI.Message structs match the existing
    # chat-completions raw-map shape for `role` and `content`, so existing
    # pattern matches keep working unchanged.

    test "User struct matches a chat-completions role+content pattern" do
      msg = Message.user("hi")
      assert %{role: "user", content: "hi"} = msg
    end

    test "Assistant struct matches a chat-completions role+content pattern" do
      msg = Message.assistant("ok")
      assert %{role: "assistant", content: "ok"} = msg
    end

    test "System struct matches a chat-completions role+content pattern" do
      msg = Message.system("be brief")
      assert %{role: "developer", content: "be brief"} = msg
    end
  end
end

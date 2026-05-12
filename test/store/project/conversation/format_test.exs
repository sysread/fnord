defmodule Store.Project.Conversation.FormatTest do
  use Fnord.TestCase, async: false

  alias Store.Project.Conversation
  alias Store.Project.Conversation.Format

  setup do
    {:ok, project: mock_project("fmt_test")}
  end

  describe "detect/1" do
    test "recognizes the v0 timestamp-prefix shape" do
      assert {:ok, :v0} = Format.detect("1700000000:{\"messages\":[]}")
    end

    test "recognizes the v1 pure-JSON shape" do
      assert {:ok, :v1} = Format.detect(~s|{"version":1,"timestamp":1700000000}|)
    end

    test "tolerates leading whitespace on v1" do
      assert {:ok, :v1} = Format.detect("  \n  {\"version\":1}")
    end

    test "rejects content that matches neither" do
      assert {:error, :unrecognized} = Format.detect("garbage without prefix or json")
    end
  end

  describe "timestamp_of/1" do
    test "fast path: extracts the timestamp prefix from a v0 file" do
      assert {:ok, %DateTime{} = ts} = Format.timestamp_of("1700000000:{\"messages\":[]}")
      assert DateTime.to_unix(ts) == 1_700_000_000
    end

    test "v1 path: decodes JSON and pulls the timestamp field" do
      v1 = ~s|{"version":1,"timestamp":1700000123,"messages":[]}|
      assert {:ok, %DateTime{} = ts} = Format.timestamp_of(v1)
      assert DateTime.to_unix(ts) == 1_700_000_123
    end

    test "v1 missing the timestamp field is an error" do
      v1 = ~s|{"version":1,"messages":[]}|
      assert {:error, :invalid_timestamp} = Format.timestamp_of(v1)
    end

    test "v0 with a non-integer prefix is an error" do
      assert {:error, _} = Format.timestamp_of("abc:something")
    end
  end

  describe "read/1 v0 path (existing format)" do
    test "round-trips a written v0 conversation", ctx do
      convo = Conversation.new("rt_v0", ctx.project)

      data = %{
        messages: [%{role: "user", content: "hi"}],
        metadata: %{},
        memory: [],
        tasks: %{}
      }

      assert {:ok, _} = Conversation.write(convo, data)

      assert {:ok, read} = Format.read(convo)
      assert read.messages == [%{role: "user", content: "hi"}]
      assert %DateTime{} = read.timestamp
    end
  end

  describe "read/1 v1 path (forward-facing format)" do
    # No writer emits v1 yet - we hand-roll a v1 file on disk to verify the
    # reader handles it. Cross-worktree safety relies on this: an older
    # worktree with this build must be able to parse a v1 file written by a
    # future build.

    test "parses a hand-rolled v1 conversation", ctx do
      convo = Conversation.new("rt_v1", ctx.project)

      v1 =
        SafeJson.encode!(%{
          "version" => 1,
          "timestamp" => 1_700_000_000,
          "messages" => [%{"role" => "user", "content" => "hi v1"}],
          "metadata" => %{},
          "memory" => [],
          "tasks" => %{}
        })

      File.mkdir_p!(Path.dirname(convo.store_path))
      File.write!(convo.store_path, v1)

      assert {:ok, read} = Format.read(convo)
      assert read.messages == [%{role: "user", content: "hi v1"}]
      assert DateTime.to_unix(read.timestamp) == 1_700_000_000
    end

    test "v1 with malformed JSON yields :corrupt_conversation", ctx do
      convo = Conversation.new("bad_v1", ctx.project)
      File.mkdir_p!(Path.dirname(convo.store_path))
      File.write!(convo.store_path, "{not valid json")

      # The content starts with `{` so detect/1 returns :v1, then SafeJson
      # fails inside parse_v1. Either path surfaces as corrupt_conversation.
      assert {:error, {:corrupt_conversation, _}} = Format.read(convo)
    end

    test "completely unrecognizable content surfaces as :corrupt_conversation", ctx do
      convo = Conversation.new("garbage", ctx.project)
      File.mkdir_p!(Path.dirname(convo.store_path))
      File.write!(convo.store_path, "this is neither v0 nor v1")

      assert {:error, {:corrupt_conversation, :unrecognized_format}} = Format.read(convo)
    end
  end

  describe "read/1 heal-on-read for v0 tool-call arguments" do
    test "re-encodes map-valued arguments back to a JSON string and persists", ctx do
      convo = Conversation.new("heal_args", ctx.project)

      # Simulate a v0 file that was written by the removed code path that
      # stored tool_calls[].function.arguments as a decoded map. The heal
      # pass must re-encode to a JSON string AND persist the fix.
      bad_data =
        SafeJson.encode!(%{
          "messages" => [
            %{
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                %{
                  "id" => "c1",
                  "type" => "function",
                  "function" => %{
                    "name" => "search",
                    "arguments" => %{"q" => "foo"}
                  }
                }
              ]
            }
          ],
          "metadata" => %{},
          "memory" => [],
          "tasks" => %{}
        })

      File.mkdir_p!(Path.dirname(convo.store_path))
      File.write!(convo.store_path, "1700000000:" <> bad_data)

      assert {:ok, _} = Format.read(convo)

      # Persisted form on disk should now have a string argument.
      raw = File.read!(convo.store_path)
      assert [_, json] = String.split(raw, ":", parts: 2)
      assert {:ok, decoded} = SafeJson.decode(json)

      [healed_call] = decoded["messages"] |> hd() |> Map.get("tool_calls")
      assert is_binary(healed_call["function"]["arguments"])
      assert healed_call["function"]["arguments"] =~ "foo"
    end
  end
end

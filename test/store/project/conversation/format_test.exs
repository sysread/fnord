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
      assert [%AI.Message.User{role: "user", content: "hi"}] = read.messages
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
      assert [%AI.Message.User{role: "user", content: "hi v1"}] = read.messages
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

  describe "read/1 heal-on-read for v0 task lists" do
    test "task-list shape heal also rewrites the file as v1 (not back to v0)", ctx do
      # Parallel to the tool-call-args heal test below. Both heal passes
      # must agree on the persisted format - either both write v0 or both
      # write v1. Inconsistency was a real bug: TaskListStatusMigration
      # used to rewrite back as v0 while heal_tool_call_arguments emitted
      # v1, so the on-disk format after heal depended on which pass fired.
      convo = Conversation.new("heal_tasks", ctx.project)

      # Legacy task shape: bare list of tasks under a list_id, instead of
      # the canonical %{"tasks" => [...], "description" => ..., "status" => ...}.
      # Tasks themselves use the %{id, data, ...} shape that
      # `Services.Task.new_task/3` expects when finalize_tasks/1 hydrates.
      bad_data =
        SafeJson.encode!(%{
          "messages" => [],
          "metadata" => %{},
          "memory" => [],
          "tasks" => %{"list-1" => [%{"id" => "t1", "data" => "do the thing"}]}
        })

      File.mkdir_p!(Path.dirname(convo.store_path))
      File.write!(convo.store_path, "1700000000:" <> bad_data)

      assert {:ok, _} = Format.read(convo)

      raw = File.read!(convo.store_path)
      assert {:ok, decoded} = SafeJson.decode(raw)
      assert decoded["version"] == 1
      assert decoded["timestamp"] == 1_700_000_000

      # The legacy bare list got upgraded to the canonical map shape.
      healed_list = decoded["tasks"]["list-1"]
      assert healed_list["status"] == "planning"
      assert [%{"id" => "t1", "data" => "do the thing"}] = healed_list["tasks"]
    end
  end

  describe "read/1 heal-on-read combined passes (both repairs in one file)" do
    # Earlier each heal pass persisted independently. If both fired on the
    # same v0 file, the second write built its JSON from data the first
    # write had repaired in memory but NOT threaded forward - so the
    # second write clobbered the first repair on disk. parse_v0/2 now
    # composes both heals as pure functions and writes once at the end.
    test "both heals run together; persisted v1 file carries both repairs", ctx do
      convo = Conversation.new("heal_combined", ctx.project)

      # File needs BOTH:
      #  - task list in legacy bare-list shape
      #  - tool_call.function.arguments stored as a decoded map instead of a JSON string
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
          "tasks" => %{"list-1" => [%{"id" => "t1", "data" => "do the thing"}]}
        })

      File.mkdir_p!(Path.dirname(convo.store_path))
      File.write!(convo.store_path, "1700000000:" <> bad_data)

      assert {:ok, _} = Format.read(convo)

      raw = File.read!(convo.store_path)
      assert {:ok, decoded} = SafeJson.decode(raw)
      assert decoded["version"] == 1
      assert decoded["timestamp"] == 1_700_000_000

      # Tool-call args repair survived.
      [healed_call] = decoded["messages"] |> hd() |> Map.get("tool_calls")
      assert is_binary(healed_call["function"]["arguments"])
      assert healed_call["function"]["arguments"] =~ "foo"

      # Task-list repair survived (this is the one the prior bug would have
      # clobbered - second write built from data without the task heal).
      healed_list = decoded["tasks"]["list-1"]
      assert healed_list["status"] == "planning"
      assert [%{"id" => "t1", "data" => "do the thing"}] = healed_list["tasks"]
    end

    test "clean v0 file with already-canonical tasks does not trigger a heal-write", ctx do
      # Only the tool-call args heal flag should trip when there's nothing
      # to repair. Verify a clean read leaves the file untouched (still v0
      # on disk, no atomic-rename has happened).
      convo = Conversation.new("heal_noop", ctx.project)

      clean_data =
        SafeJson.encode!(%{
          "messages" => [%{"role" => "user", "content" => "hi"}],
          "metadata" => %{},
          "memory" => [],
          "tasks" => %{
            "list-1" => %{
              "tasks" => [],
              "description" => nil,
              "status" => "planning"
            }
          }
        })

      File.mkdir_p!(Path.dirname(convo.store_path))
      v0_blob = "1700000000:" <> clean_data
      File.write!(convo.store_path, v0_blob)

      assert {:ok, _} = Format.read(convo)

      # File still in v0 form - no heal-write fired.
      raw = File.read!(convo.store_path)
      assert raw == v0_blob
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

      # The healed file is rewritten as v1 (pure JSON with `version: 1` and a
      # top-level `timestamp` field). The legacy <ts>: prefix is gone. The
      # rewrite-on-heal pattern is what migrates straggling v0 files forward
      # to v1 incrementally on first read.
      raw = File.read!(convo.store_path)
      assert {:ok, decoded} = SafeJson.decode(raw)
      assert decoded["version"] == 1
      assert decoded["timestamp"] == 1_700_000_000

      [healed_call] = decoded["messages"] |> hd() |> Map.get("tool_calls")
      assert is_binary(healed_call["function"]["arguments"])
      assert healed_call["function"]["arguments"] =~ "foo"
    end
  end

  describe "write/3 v1 emission" do
    test "Conversation.write/2 emits v1 (pure JSON, version + timestamp in body)", ctx do
      convo = Conversation.new("v1_write", ctx.project)

      assert {:ok, _} =
               Conversation.write(convo, %{
                 messages: [AI.Util.user_msg("hi")],
                 metadata: %{},
                 memory: [],
                 tasks: %{}
               })

      raw = File.read!(convo.store_path)

      # No legacy timestamp prefix - file must start with `{`.
      assert String.starts_with?(raw, "{")
      assert {:ok, decoded} = SafeJson.decode(raw)
      assert decoded["version"] == 1
      assert is_integer(decoded["timestamp"])
      assert decoded["messages"] == [%{"role" => "user", "content" => "hi"}]
    end

    test "Conversation.write/2 round-trip preserves user/assistant messages", ctx do
      convo = Conversation.new("v1_roundtrip", ctx.project)

      original = [
        AI.Util.system_msg("be brief"),
        AI.Util.user_msg("hello"),
        AI.Util.assistant_msg("hi")
      ]

      assert {:ok, _} = Conversation.write(convo, %{messages: original})
      assert {:ok, %{messages: read}} = Conversation.read(convo)
      assert read == original
    end
  end
end

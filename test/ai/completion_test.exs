defmodule AI.CompletionTest do
  use Fnord.TestCase, async: false

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
      # The first message is implicitly added by AI.Completion. It is the agent's name.
      assert [_, %{role: "user", content: "yo"}] = state.messages
      assert state.log_msgs == false
      assert state.replay_conversation == true
      assert is_nil(state.specs)
    end

    test "stores optional verbosity from opts" do
      opts = [
        model: "test-model",
        messages: [%{role: "user", content: "yo"}],
        verbosity: "high"
      ]

      assert {:ok, state} = AI.Completion.new(opts)
      assert state.verbosity == "high"
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

    test "parses optional toolbox and toggles options when toolbox is empty" do
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
      assert is_nil(state.toolbox)
      assert is_nil(state.specs)
      assert state.log_msgs == true
      assert state.replay_conversation == false
      assert state.archive_notes == true
    end

    test "parses optional toolbox and toggles options when toolbox is not empty" do
      my_toolbox = AI.Tools.basic_tools()

      opts = [
        model: "x",
        messages: [],
        toolbox: my_toolbox,
        log_msgs: true,
        replay_conversation: false,
        archive_notes: true
      ]

      assert {:ok, state} = AI.Completion.new(opts)
      assert is_map(state.toolbox)
      assert is_list(state.specs)
      assert map_size(state.toolbox) == map_size(my_toolbox)
      assert length(state.specs) == map_size(my_toolbox)
      assert state.log_msgs == true
      assert state.replay_conversation == false
      assert state.archive_notes == true
    end
  end

  describe "new_from_conversation/2" do
    setup do
      {:ok, project: mock_project("test_project")}
    end

    test "returns error if conversation does not exist" do
      conv = Store.Project.Conversation.new()
      assert {:error, :conversation_not_found} = AI.Completion.new_from_conversation(conv, [])
    end

    test "returns error if opts missing :model" do
      messages = [
        AI.Util.system_msg("You are a helpful assistant."),
        AI.Util.user_msg("Hello, I am User."),
        AI.Util.assistant_msg("That is lovely. I am Assistant.")
      ]

      conv = Store.Project.Conversation.new()

      assert {:ok, conv} =
               Store.Project.Conversation.write(conv, %{
                 messages: messages,
                 metadata: %{},
                 memories: []
               })

      assert :error = AI.Completion.new_from_conversation(conv, [])
    end

    test "returns ok state if valid conversation and opts" do
      messages = [
        AI.Util.system_msg("You are a helpful assistant."),
        AI.Util.user_msg("Hello, I am User."),
        AI.Util.assistant_msg("That is lovely. I am Assistant.")
      ]

      conv = Store.Project.Conversation.new()

      assert {:ok, conv} =
               Store.Project.Conversation.write(conv, %{
                 messages: messages,
                 metadata: %{},
                 memories: []
               })

      model = AI.Model.new("fake", 42)
      assert {:ok, state} = AI.Completion.new_from_conversation(conv, model: model)
      assert state.model == model
      # The first message is implicitly added by AI.Completion. It is the agent's name.
      assert [_ | ^messages] = state.messages
    end
  end

  describe "get/1" do
    test "Completion.get/1 passes nil verbosity to the API layer" do
      :meck.expect(AI.CompletionAPI, :get, fn _model,
                                              _msgs,
                                              _specs,
                                              _res_fmt,
                                              _web_srch?,
                                              verbosity ->
        assert is_nil(verbosity)
        {:ok, :msg, "ok", 7}
      end)

      assert {:ok, state} =
               AI.Completion.get(
                 model: AI.Model.new("dummy", 0),
                 messages: [%{role: "user", content: "hi"}],
                 toolbox: %{},
                 verbosity: nil
               )

      assert state.response == "ok"
    end

    test "Completion.get/1 forwards verbosity to the API" do
      :meck.expect(AI.CompletionAPI, :get, fn _model,
                                              _msgs,
                                              _specs,
                                              _res_fmt,
                                              _web_srch?,
                                              verbosity ->
        assert verbosity == "low"
        {:ok, :msg, "ok", 7}
      end)

      assert {:ok, state} =
               AI.Completion.get(
                 model: AI.Model.new("dummy", 0),
                 messages: [%{role: "user", content: "hi"}],
                 toolbox: %{},
                 verbosity: "low"
               )

      assert state.response == "ok"
    end

    test "Completion.get/1 surfaces API error response to user" do
      :meck.expect(AI.CompletionAPI, :get, fn _model,
                                              _msgs,
                                              _specs,
                                              _res_fmt,
                                              _web_srch?,
                                              _verbosity ->
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

    test "Completion.get/1 surfaces structured error field response to user" do
      :meck.expect(AI.CompletionAPI, :get, fn _model,
                                              _msgs,
                                              _specs,
                                              _res_fmt,
                                              _web_srch?,
                                              _verbosity ->
        {:error, %{http_status: 500, error: "Unexpected response %{foo: :bar}"}}
      end)

      user_msg = %{role: "user", content: "trigger error"}

      assert {:error, state} =
               AI.Completion.get(
                 model: AI.Model.new("dummy", 0),
                 messages: [user_msg],
                 toolbox: %{}
               )

      assert state.response =~ "HTTP Status: 500"
      assert state.response =~ "Error: Unexpected response %{foo: :bar}"
    end

    test "Completion.get/1 inspects non-binary structured error field values" do
      :meck.expect(AI.CompletionAPI, :get, fn _model,
                                              _msgs,
                                              _specs,
                                              _res_fmt,
                                              _web_srch?,
                                              _verbosity ->
        {:error, %{http_status: 500, error: %{foo: :bar}}}
      end)

      user_msg = %{role: "user", content: "trigger error"}

      assert {:error, state} =
               AI.Completion.get(
                 model: AI.Model.new("dummy", 0),
                 messages: [user_msg],
                 toolbox: %{}
               )

      assert state.response =~ "HTTP Status: 500"
      assert state.response =~ "Error: %{foo: :bar}"
    end

    test "Completion.get/1 surfaces rate limit error response and can print it" do
      :meck.expect(AI.CompletionAPI, :get, fn _model,
                                              _msgs,
                                              _specs,
                                              _res_fmt,
                                              _web_srch?,
                                              _verbosity ->
        {:error, %{http_status: 429, code: "rate_limit", message: "Rate limit exceeded"}}
      end)

      user_msg = %{role: "user", content: "trigger error"}

      assert {:error, state} =
               AI.Completion.get(
                 model: AI.Model.new("dummy", 0),
                 messages: [user_msg],
                 toolbox: %{}
               )

      {output, _stderr} = capture_all(fn -> IO.puts(state.response) end)

      assert output =~ "429"
      assert output =~ "rate_limit"
      assert output =~ "Rate limit exceeded"
    end
  end

  describe "tools_used/1" do
    test "returns empty map if no messages" do
      assert %{} =
               AI.Completion.tools_used(%AI.Completion{
                 messages: [],
                 initial_message_count: 0
               })
    end

    test "counts tools appended after the initial message snapshot" do
      initial = [AI.Util.user_msg("start")]

      messages =
        initial ++
          [
            %{
              tool_calls: [
                %{function: %{name: "foo"}},
                %{function: %{name: "bar"}},
                %{function: %{name: "foo"}}
              ]
            }
          ]

      assert %{"foo" => 2, "bar" => 1} =
               AI.Completion.tools_used(%AI.Completion{
                 messages: messages,
                 initial_message_count: length(initial)
               })
    end

    test "returns tool call counts across multiple messages" do
      initial = [AI.Util.user_msg("hello")]

      messages =
        initial ++
          [
            %{tool_calls: [%{function: %{name: "foo"}}]},
            %{},
            %{tool_calls: [%{function: %{name: "foo"}}, %{function: %{name: "bar"}}]}
          ]

      assert %{"foo" => 2, "bar" => 1} =
               AI.Completion.tools_used(%AI.Completion{
                 messages: messages,
                 initial_message_count: length(initial)
               })
    end

    test "ignores messages with no tool_calls key or non-matching entries" do
      messages = [
        %{},
        %{unexpected: 123, content: "skip me"},
        %{tool_calls: []}
      ]

      assert %{} =
               AI.Completion.tools_used(%AI.Completion{
                 messages: messages,
                 initial_message_count: 0
               })
    end

    test "ignores tool calls present before the initial snapshot" do
      # Tool calls that already existed in the input messages must not be
      # counted - they belong to a prior completion round.
      initial = [
        %{tool_calls: [%{function: %{name: "before"}}]},
        AI.Util.user_msg("continue")
      ]

      messages =
        initial ++
          [
            %{
              tool_calls: [
                %{function: %{name: "after1"}},
                %{function: %{name: "after2"}}
              ]
            }
          ]

      assert %{"after1" => 1, "after2" => 1} ==
               AI.Completion.tools_used(%AI.Completion{
                 messages: messages,
                 initial_message_count: length(initial)
               })
    end

    test "still counts tools when an interrupt user message arrives mid-round" do
      # Regression: a user interjection injected mid-completion via
      # maybe_apply_interrupts/1 used to become the new "last user message"
      # under the old heuristic, hiding any tool calls that fired earlier in
      # the same round and silently flipping editing_tools_used off. The
      # initial_message_count snapshot is stable across mid-round user message
      # injection.
      initial = [AI.Util.user_msg("implement the banner")]

      messages =
        initial ++
          [
            %{tool_calls: [%{function: %{name: "file_edit_tool"}}]},
            %{tool_calls: [%{function: %{name: "file_edit_tool"}}]},
            AI.Util.user_msg("[User Interjection] also fix the test failures"),
            %{tool_calls: [%{function: %{name: "notify_tool"}}]}
          ]

      assert %{"file_edit_tool" => 2, "notify_tool" => 1} ==
               AI.Completion.tools_used(%AI.Completion{
                 messages: messages,
                 initial_message_count: length(initial)
               })
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

      @impl AI.Tools
      def tool_call_failure_message(_args, _reason), do: :default
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

      @impl AI.Tools
      def tool_call_failure_message(_args, _reason), do: :default
    end

    test "Completion.get/1 invokes local tools from toolbox" do
      :meck.expect(AI.CompletionAPI, :get, fn _model,
                                              msgs,
                                              _specs,
                                              _res_fmt,
                                              _web_srch?,
                                              _verbosity ->
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

      assert Enum.any?(state.messages, fn msg ->
               msg.role == "assistant" and msg.content == nil and Map.has_key?(msg, :tool_calls)
             end)

      assert Enum.any?(state.messages, fn msg ->
               msg.role == "tool" and msg.name == "test_tool" and msg.content =~ "tool_result"
             end)

      assert List.last(state.messages).role == "assistant"
      assert List.last(state.messages).content == "final response"
    end

    test "Tool calls invocation respects async?/0" do
      :meck.expect(AI.CompletionAPI, :get, fn _model,
                                              msgs,
                                              _specs,
                                              _response_fmt,
                                              _web_srch?,
                                              _verbosity ->
        tool_calls_sent? = Enum.any?(msgs, fn msg -> Map.has_key?(msg, :tool_calls) end)

        if tool_calls_sent? do
          {:ok, :msg, "final response", 0}
        else
          {:ok, :tool,
           [
             %{id: 1, function: %{name: "test_tool_sync", arguments: "{}"}},
             %{id: 2, function: %{name: "test_tool", arguments: "{}"}},
             %{id: 3, function: %{name: "test_tool_sync", arguments: "{\"dummy\":true}"}},
             %{id: 3, function: %{name: "test_tool_sync", arguments: "{\"dummy\":true}"}}
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

      assert tool_call_ids_in_order == [2, 1, 3]

      # Final assistant message after tool calls
      assert List.last(state.messages).role == "assistant"
      assert List.last(state.messages).content == "final response"
    end

    test "Completion.get/1 handles unknown tool requests gracefully" do
      :meck.expect(AI.CompletionAPI, :get, fn _model,
                                              msgs,
                                              _specs,
                                              _res_fmt,
                                              _web_srch?,
                                              _verbosity ->
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

    test "deduplicates identical tool calls within a single batch and preserves order" do
      # First API.get returns duplicated tool calls, second returns final assistant message
      :meck.expect(AI.CompletionAPI, :get, fn _model,
                                              msgs,
                                              _specs,
                                              _res_fmt,
                                              _web_srch?,
                                              _verbosity ->
        if Enum.any?(msgs, fn msg -> Map.has_key?(msg, :tool_calls) end) do
          {:ok, :msg, "done", 0}
        else
          calls = [
            %{id: 1, function: %{name: "test_tool", arguments: ~s({"b":2,"a":1})}},
            %{id: 2, function: %{name: "test_tool_sync", arguments: "{}"}},
            %{id: 3, function: %{name: "test_tool", arguments: ~s({"a":1,"b":2})}}
          ]

          {:ok, :tool, calls}
        end
      end)

      user_msg = %{role: "user", content: "invoke tools"}

      assert {:ok, state} =
               AI.Completion.get(
                 model: AI.Model.new("dummy", 0),
                 messages: [user_msg],
                 toolbox: %{"test_tool" => TestTool, "test_tool_sync" => TestToolSync}
               )

      # Only unique calls should be executed in order
      executed =
        state.messages
        |> Enum.filter(&(&1.role == "tool"))
        |> Enum.map(&{&1.tool_call_id, &1.name})

      assert executed == [{1, "test_tool"}, {2, "test_tool_sync"}]
      # Final assistant message
      assert List.last(state.messages).role == "assistant"
      assert List.last(state.messages).content == "done"
    end
  end

  describe "tool-round cap" do
    # Repro of the verify-thrashing pathology: a stuck model keeps asking
    # for tool calls without ever emitting a final response. After
    # `tool_round_cap` rounds, Completion should drop the tool surface,
    # inject a system nudge, and let the model finalize on the next call.
    test "stuck tool-call loop terminates after cap with nudge injected" do
      System.put_env("FNORD_TOOL_ROUND_CAP", "3")
      on_exit(fn -> System.delete_env("FNORD_TOOL_ROUND_CAP") end)

      # Track how many times the API has been called. Returns :tool for
      # as long as specs is a list (before the cap drops it), and :msg
      # once specs has been withdrawn.
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      # on_exit runs in a separate process; by then the Agent may already
      # be shutting down via its link to the test pid. Agent.stop waits
      # for a :normal exit and errors on any other reason, which racily
      # reports a clean test as a CI failure. Fire-and-forget kill is
      # race-safe: the Agent is unreferenced after the test body anyway.
      on_exit(fn ->
        if Process.alive?(counter), do: Process.exit(counter, :shutdown)
      end)

      :meck.expect(AI.CompletionAPI, :get, fn _model,
                                              _msgs,
                                              specs,
                                              _res_fmt,
                                              _web_srch?,
                                              _verbosity ->
        count = Agent.get_and_update(counter, fn c -> {c + 1, c + 1} end)

        if is_nil(specs) do
          {:ok, :msg, "final response after cap (round #{count})", 0}
        else
          tool_call = %{id: count, function: %{name: "test_tool", arguments: "{}"}}
          {:ok, :tool, [tool_call]}
        end
      end)

      user_msg = %{role: "user", content: "go"}

      assert {:ok, state} =
               AI.Completion.get(
                 model: AI.Model.new("dummy", 0),
                 messages: [user_msg],
                 toolbox: %{"test_tool" => __MODULE__.TestTool}
               )

      # The nudge was injected after the cap was reached.
      assert Enum.any?(state.messages, fn msg ->
               content = Map.get(msg, :content) || ""
               content =~ "rounds of tool calls" and content =~ "cap"
             end)

      # Tool surface was withdrawn. Toolbox is an empty-map sentinel (not
      # nil) so any straggling tool call routes to :unknown_tool instead of
      # the default basic+MCP fallback in AI.Tools.tool_module/2.
      assert state.specs == nil
      assert state.toolbox == %{}

      # Final response came from the model's :msg reply after the cap.
      assert state.response =~ "final response after cap"
      assert state.tool_round_count == 3
    end

    test "env var FNORD_TOOL_ROUND_CAP overrides the default" do
      System.put_env("FNORD_TOOL_ROUND_CAP", "42")
      on_exit(fn -> System.delete_env("FNORD_TOOL_ROUND_CAP") end)

      assert {:ok, state} =
               AI.Completion.new(
                 model: "m",
                 messages: [%{role: "user", content: "yo"}]
               )

      assert state.tool_round_cap == 42
    end

    test "invalid FNORD_TOOL_ROUND_CAP falls back to the default" do
      System.put_env("FNORD_TOOL_ROUND_CAP", "not-a-number")
      on_exit(fn -> System.delete_env("FNORD_TOOL_ROUND_CAP") end)

      assert {:ok, state} =
               AI.Completion.new(
                 model: "m",
                 messages: [%{role: "user", content: "yo"}]
               )

      # Non-integer falls back to the compiled-in default; assert it is at
      # least positive without pinning the constant value.
      assert state.tool_round_cap >= 1
    end
  end
end

defmodule AI.ResponsesTest do
  use Fnord.TestCase, async: false

  setup do
    :meck.new(AI.ResponsesAPI, [:no_link, :passthrough, :non_strict])
    on_exit(fn -> :meck.unload(AI.ResponsesAPI) end)
    :ok
  end

  describe "new/1" do
    test "creates responses state with minimal valid opts" do
      opts = [
        model: "test-model",
        messages: [%{role: "user", content: "yo"}]
      ]

      assert {:ok, state} = AI.Responses.new(opts)
      assert state.model == "test-model"
      # The first message is implicitly added by AI.Responses. It is the agent's name.
      assert [_, %{role: "user", content: "yo"}] = state.messages
      assert state.log_msgs == false
      assert state.replay_conversation == true
      assert is_nil(state.specs)
    end

    test "returns error when :model is missing" do
      opts = [messages: [%{role: "user", content: "yo"}]]
      assert :error = AI.Responses.new(opts)
    end

    test "returns error when :messages is missing" do
      opts = [model: "test-model"]
      assert :error = AI.Responses.new(opts)
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

      assert {:ok, state} = AI.Responses.new(opts)
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

      assert {:ok, state} = AI.Responses.new(opts)
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
      assert {:error, :conversation_not_found} = AI.Responses.new_from_conversation(conv, [])
    end

    test "returns error if opts missing :model" do
      messages = [
        AI.Util.system_msg("You are a helpful assistant."),
        AI.Util.user_msg("Hello, I am User."),
        AI.Util.assistant_msg("That is lovely. I am Assistant.")
      ]

      conv = Store.Project.Conversation.new()
      assert {:ok, conv} = Store.Project.Conversation.write(conv, messages)
      assert :error = AI.Responses.new_from_conversation(conv, [])
    end

    test "returns ok state if valid conversation and opts" do
      messages = [
        AI.Util.system_msg("You are a helpful assistant."),
        AI.Util.user_msg("Hello, I am User."),
        AI.Util.assistant_msg("That is lovely. I am Assistant.")
      ]

      conv = Store.Project.Conversation.new()
      assert {:ok, conv} = Store.Project.Conversation.write(conv, messages)

      model = AI.Model.new("fake", 42)
      assert {:ok, state} = AI.Responses.new_from_conversation(conv, model: model)
      assert state.model == model
      # The first message is implicitly added by AI.Responses. It is the agent's name.
      assert [_ | ^messages] = state.messages
    end
  end

  describe "get/1" do
    test "Responses.get/1 surfaces API error response to user" do
      :meck.expect(AI.ResponsesAPI, :get, fn _model, _msgs, _specs, _res_fmt, _web_srch? ->
        {:error, %{http_status: 500, code: "server_error", message: "backend exploded"}}
      end)

      user_msg = %{role: "user", content: "trigger error"}

      assert {:error, state} =
               AI.Responses.get(
                 model: AI.Model.new("dummy", 0),
                 messages: [user_msg],
                 toolbox: %{}
               )

      assert state.response =~ "HTTP Status: 500"
      assert state.response =~ "Error code: server_error"
      assert state.response =~ "backend exploded"
    end

    test "Responses.get/1 surfaces rate limit error response and can print it" do
      :meck.expect(AI.ResponsesAPI, :get, fn _model, _msgs, _specs, _res_fmt, _web_srch? ->
        {:error, %{http_status: 429, code: "rate_limit", message: "Rate limit exceeded"}}
      end)

      user_msg = %{role: "user", content: "trigger error"}

      assert {:error, state} =
               AI.Responses.get(
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
end

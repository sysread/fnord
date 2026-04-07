defmodule AI.Agent.Coordinator.GlueToolsTest do
  use Fnord.TestCase, async: false

  setup do
    set_log_level(:none)

    safe_meck_new(UI, [:passthrough])
    :meck.new(GitCli, [:passthrough])

    on_exit(fn ->
      try do
        safe_meck_unload(UI)
      rescue
        _ -> :ok
      end

      try do
        :meck.unload(GitCli)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  test "coordinator includes ui tools only when tty and not quiet" do
    :meck.expect(UI, :is_tty?, 0, true)
    :meck.expect(UI, :quiet?, 0, false)

    for edit <- [false, true] do
      tools = AI.Agent.Coordinator.Glue.get_tools(%{edit?: edit})

      assert Map.has_key?(tools, "ui_ask_tool")
      assert Map.has_key?(tools, "ui_choose_tool")
      assert Map.has_key?(tools, "ui_confirm_tool")
    end
  end

  test "coordinator excludes ui tools when not a tty" do
    :meck.expect(UI, :is_tty?, 0, false)
    :meck.expect(UI, :quiet?, 0, false)

    for edit <- [false, true] do
      tools = AI.Agent.Coordinator.Glue.get_tools(%{edit?: edit})

      refute Map.has_key?(tools, "ui_ask_tool")
      refute Map.has_key?(tools, "ui_choose_tool")
      refute Map.has_key?(tools, "ui_confirm_tool")
    end
  end

  test "coordinator excludes ui tools when quiet" do
    :meck.expect(UI, :is_tty?, 0, true)
    :meck.expect(UI, :quiet?, 0, true)

    for edit <- [false, true] do
      tools = AI.Agent.Coordinator.Glue.get_tools(%{edit?: edit})

      refute Map.has_key?(tools, "ui_ask_tool")
      refute Map.has_key?(tools, "ui_choose_tool")
      refute Map.has_key?(tools, "ui_confirm_tool")
    end
  end

  test "coordinator worktree tool is gated on edit mode and git repo" do
    :meck.expect(UI, :is_tty?, 0, false)
    :meck.expect(UI, :quiet?, 0, false)
    :meck.expect(GitCli, :is_git_repo?, 0, true)

    edit_tools = AI.Agent.Coordinator.Glue.get_tools(%{edit?: true})
    non_edit_tools = AI.Agent.Coordinator.Glue.get_tools(%{edit?: false})

    assert Map.has_key?(edit_tools, "git_worktree_tool")
    refute Map.has_key?(non_edit_tools, "git_worktree_tool")
  end

  test "coordinator worktree tool is omitted outside git repos" do
    :meck.expect(UI, :is_tty?, 0, false)
    :meck.expect(UI, :quiet?, 0, false)
    :meck.expect(GitCli, :is_git_repo?, 0, false)

    tools = AI.Agent.Coordinator.Glue.get_tools(%{edit?: true})

    refute Map.has_key?(tools, "git_worktree_tool")
  end

  describe "validation integration" do
    setup do
      :meck.new(Services.Conversation, [:passthrough])
      :meck.new(Services.Conversation.Interrupts, [:passthrough])
      :meck.new(AI.Agent, [:passthrough])
      :meck.new(Validation.Rules, [:passthrough])

      on_exit(fn ->
        for module <- [
              Services.Conversation,
              Services.Conversation.Interrupts,
              AI.Agent,
              Validation.Rules
            ] do
          try do
            :meck.unload(module)
          rescue
            _ -> :ok
          end
        end
      end)

      :ok
    end

    test "does not run validation when no code-modifying tools were used" do
      state = %{
        agent: :coordinator,
        conversation_pid: self(),
        model: AI.Model.smart(),
        context: 100,
        editing_tools_used: false,
        last_validation_fingerprint: nil
      }

      :meck.expect(Services.Conversation, :get_messages, fn _ -> [] end)
      :meck.expect(Services.Conversation, :save, fn _conversation -> {:ok, %{id: "conv-1"}} end)

      :meck.expect(Services.Conversation, :replace_msgs, fn conversation, _messages ->
        conversation
      end)

      :meck.expect(Services.Conversation, :append_msg, fn conversation, _message ->
        conversation
      end)

      :meck.expect(Services.Conversation.Interrupts, :pending?, fn _ -> false end)

      :meck.expect(AI.Agent, :get_completion, fn _, _ ->
        {:ok,
         %{
           response: "done",
           messages: [
             %{role: "user", content: "do it"},
             %{role: "assistant", content: "done"}
           ],
           usage: 2,
           tool_calls: []
         }}
      end)

      :meck.expect(Validation.Rules, :run, fn ->
        raise "validation should not run"
      end)

      assert %{last_validation_fingerprint: nil} =
               AI.Agent.Coordinator.Glue.get_completion(state, false)
    end

    test "records validation fingerprint when code-modifying tools were used" do
      state = %{
        agent: :coordinator,
        conversation_pid: self(),
        model: AI.Model.smart(),
        context: 100,
        editing_tools_used: false,
        last_validation_fingerprint: nil
      }

      :meck.expect(Services.Conversation, :get_messages, fn _ -> [] end)
      :meck.expect(Services.Conversation, :save, fn _conversation -> {:ok, %{id: "conv-1"}} end)

      :meck.expect(Services.Conversation, :replace_msgs, fn conversation, _messages ->
        conversation
      end)

      :meck.expect(Services.Conversation, :append_msg, fn conversation, _message ->
        conversation
      end)

      :meck.expect(Services.Conversation.Interrupts, :pending?, fn _ -> false end)

      :meck.expect(AI.Agent, :get_completion, fn _, _ ->
        {:ok,
         %{
           response: "done",
           messages: [
             %{role: "user", content: "do it"},
             %{
               role: "assistant",
               content: nil,
               tool_calls: [
                 %{function: %{name: "file_edit_tool"}}
               ]
             }
           ],
           usage: 2,
           tool_calls: [
             %{
               function: %{name: "file_edit_tool"}
             }
           ]
         }}
      end)

      :meck.expect(Validation.Rules, :run, fn ->
        {:ok, :no_matches, ["lib/foo.ex"], "fp-1"}
      end)

      :meck.expect(Validation.Rules, :summarize, fn _ ->
        "No validation rules matched for lib/foo.ex"
      end)

      assert %{last_validation_fingerprint: "fp-1"} =
               AI.Agent.Coordinator.Glue.get_completion(state, false)
    end
  end
end

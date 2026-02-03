defmodule AI.CompletionOutputReplayTest do
  use Fnord.TestCase
  @moduletag :capture_log

  test "replay uses all_tools to render tool call UI notes even if tool not in basic toolbox" do
    # Build a minimal completion state with a transcript that includes a tool call
    # to a task tool (e.g., tasks_show_list) which is NOT in basic_tools/0.
    tool_call_id = "call-1"

    messages = [
      AI.Util.system_msg("agent system prompt"),
      %{
        "role" => "assistant",
        "content" => nil,
        "tool_calls" => [
          %{
            "id" => tool_call_id,
            "type" => "function",
            "function" => %{
              "name" => "file_list_tool",
              "arguments" => %{"list_id" => 1} |> Jason.encode!()
            }
          }
        ]
      },
      %{
        "role" => "tool",
        "name" => "file_list_tool",
        "tool_call_id" => tool_call_id,
        "content" => {:ok, "[output goes here]"}
      }
    ]

    state = %AI.Completion{
      name: "TestAgent",
      messages: messages,
      log_tool_calls: true,
      replay_conversation: true
    }

    # Mock UI to capture report calls so we can assert tool UI was rendered
    :meck.new(UI, [:no_link, :passthrough, :non_strict])
    on_exit(fn -> :meck.unload(UI) end)

    # Capture any UI.report_from/2 or /3 calls
    parent = self()

    :meck.expect(UI, :report_from, fn name, step, msg ->
      send(parent, {:ui_step_msg, name, step, msg})
      :ok
    end)

    :meck.expect(UI, :report_from, fn name, step ->
      send(parent, {:ui_step, name, step})
      :ok
    end)

    # Exercise: this will internally build `tool_call_args`, switch toolbox to AI.Tools.all_tools(),
    # and emit on_event(:tool_call, ...) and on_event(:tool_call_result, ...)
    AI.Completion.Output.replay_conversation(state)

    # Assert: we saw UI output indicating tool UI notes were produced
    receive do
      {:ui_step_msg, "TestAgent", _step, _msg} -> :ok
      {:ui_step, "TestAgent", _step} -> :ok
    after
      1000 -> flunk("Did not receive a UI step message or step within 1000ms")
    end
  end

  test "developer message sets agent name in replay events" do
    tool_call_id = "dev-call-1"

    messages = [
      %{"role" => "developer", "content" => "Your name is Dev Agent."},
      %{
        "role" => "assistant",
        "content" => nil,
        "tool_calls" => [
          %{
            "id" => tool_call_id,
            "type" => "function",
            "function" => %{
              "name" => "file_list_tool",
              "arguments" => %{"list_id" => 1} |> Jason.encode!()
            }
          }
        ]
      },
      %{
        "role" => "tool",
        "name" => "file_list_tool",
        "tool_call_id" => tool_call_id,
        "content" => {:ok, "[dev output]"}
      }
    ]

    state = %AI.Completion{
      name: nil,
      messages: messages,
      log_tool_calls: true,
      replay_conversation: true
    }

    :meck.new(UI, [:no_link, :passthrough, :non_strict])
    on_exit(fn -> :meck.unload(UI) end)

    parent = self()

    :meck.expect(UI, :report_from, fn name, step, msg ->
      send(parent, {:ui_step_msg, name, step, msg})
      :ok
    end)

    :meck.expect(UI, :report_from, fn name, step ->
      send(parent, {:ui_step, name, step})
      :ok
    end)

    AI.Completion.Output.replay_conversation(state)

    receive do
      {:ui_step_msg, "Dev Agent", _step, _msg} -> :ok
      {:ui_step, "Dev Agent", _step} -> :ok
    after
      2000 -> flunk("Did not receive UI report for Dev Agent within 2000ms")
    end
  end

  test "developer message sets agent name and prints final output via replay_conversation_as_output" do
    tool_call_id = "as-out-call-1"

    messages = [
      %{"role" => "developer", "content" => "Your name is Dev Agent."},
      %{
        "role" => "assistant",
        "content" => nil,
        "tool_calls" => [
          %{
            "id" => tool_call_id,
            "type" => "function",
            "function" => %{
              "name" => "file_list_tool",
              "arguments" => %{"list_id" => 1} |> Jason.encode!()
            }
          }
        ]
      },
      %{
        "role" => "tool",
        "name" => "file_list_tool",
        "tool_call_id" => tool_call_id,
        "content" => {:ok, "[output goes here]"}
      },
      %{"role" => "assistant", "content" => "Final assistant response"}
    ]

    state = %AI.Completion{
      name: nil,
      messages: messages,
      log_tool_calls: true,
      replay_conversation: true
    }

    :meck.new(UI, [:no_link, :passthrough, :non_strict])
    on_exit(fn -> :meck.unload(UI) end)

    parent = self()

    :meck.expect(UI, :report_from, fn name, step, msg ->
      send(parent, {:ui_step_msg, name, step, msg})
      :ok
    end)

    :meck.expect(UI, :report_from, fn name, step ->
      send(parent, {:ui_step, name, step})
      :ok
    end)

    :meck.expect(UI, :say, fn msg ->
      send(parent, {:ui_say, msg})
      :ok
    end)

    AI.Completion.Output.replay_conversation_as_output(state)

    receive do
      {:ui_step_msg, "Dev Agent", _step, _msg} -> :ok
      {:ui_step, "Dev Agent", _step} -> :ok
      {:ui_say, "Final assistant response"} -> :ok
    after
      2000 -> flunk("Did not receive UI report and say for Dev Agent within 2000ms")
    end
  end

  test "developer name only via AI.Completion.new_from_conversation/2 sets agent name in replay events" do
    messages = [
      %{"role" => "developer", "content" => "Your name is Dev Only."},
      %{"role" => "user", "content" => "ping"},
      %{"role" => "assistant", "content" => "hello"}
    ]

    state = %AI.Completion{
      name: nil,
      messages: messages,
      log_msgs: true,
      replay_conversation: true
    }

    :meck.new(UI, [:no_link, :passthrough, :non_strict])
    on_exit(fn -> :meck.unload(UI) end)

    parent = self()

    :meck.expect(UI, :feedback, fn :info, name, msg ->
      send(parent, {:ui_feedback, name, msg})
      :ok
    end)

    AI.Completion.Output.replay_conversation(state)

    receive do
      {:ui_feedback, "Dev Only", "hello"} -> :ok
    after
      2000 -> flunk("Did not receive UI feedback for Dev Only within 2000ms")
    end
  end
end

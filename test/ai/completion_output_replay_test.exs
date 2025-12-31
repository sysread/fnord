defmodule AI.CompletionOutputReplayTest do
  use Fnord.TestCase
  @moduletag :capture_log

  test "replay uses all_tools to render tool call UI notes even if tool not in basic toolbox" do
    # Build a minimal completion state with a transcript that includes a tool call
    # to a task tool (e.g., tasks_show_list) which is NOT in basic_tools/0.
    tool_call_id = "call-1"

    messages = [
      %{
        "role" => "system",
        "content" => "agent system prompt"
      },
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
end

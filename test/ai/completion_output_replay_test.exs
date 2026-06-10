defmodule AI.CompletionOutputReplayTest do
  use Fnord.TestCase, async: true
  @moduletag :capture_log

  import ExUnit.CaptureIO

  # Replay events surface through the UI.Output seam: report_from/feedback
  # format the agent name into the message ("⦑ name ⦒ msg", speech markers)
  # and route through log/2, which is gated on quiet?. Tests stub :log to
  # forward formatted content here and assert on it by pattern.
  setup do
    set_config(:quiet, false)

    parent = self()

    stub(UI.Output.Mock, :log, fn _level, msg ->
      send(parent, {:log, loggable_to_text(msg)})
      :ok
    end)

    :ok
  end

  # The log seam tolerates loose data (UI.Queue sanitizes chardata in
  # production, and callers occasionally embed raw terms); mirror that
  # tolerance rather than asserting strict iodata.
  defp loggable_to_text(msg) do
    IO.iodata_to_binary(msg)
  rescue
    ArgumentError -> inspect(msg)
  end

  defp assert_logged(pattern, timeout \\ 2_000) do
    receive do
      {:log, content} ->
        if content =~ pattern do
          :ok
        else
          assert_logged(pattern, timeout)
        end
    after
      timeout -> flunk("no log output matching #{inspect(pattern)} within #{timeout}ms")
    end
  end

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
              "arguments" => %{"list_id" => 1} |> SafeJson.encode!()
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

    # Exercise: this will internally build `tool_call_args`, switch toolbox to
    # AI.Tools.all_tools(), and emit on_event(:tool_call, ...) and
    # on_event(:tool_call_result, ...)
    AI.Completion.Output.replay_conversation(state)

    # Assert: tool UI notes were produced, attributed to the agent.
    assert_logged(~r/TestAgent/)
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
              "arguments" => %{"list_id" => 1} |> SafeJson.encode!()
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

    AI.Completion.Output.replay_conversation(state)

    assert_logged(~r/Dev Agent/)
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
              "arguments" => %{"list_id" => 1} |> SafeJson.encode!()
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

    # The formatter passes output through unchanged when FNORD_FORMATTER is
    # unset (the suite never sets it), so no stubbing is needed even with
    # stdout treated as a TTY. UI.say routes through UI.Output.puts, which
    # the TestStub prints - captured below.
    set_config(:stdout_tty, true)

    # stdout-as-TTY renders with ANSI color codes that split text
    # mid-phrase; strip them before asserting on content.
    output =
      capture_io(:stdio, fn ->
        AI.Completion.Output.replay_conversation_as_output(state)
      end)
      |> UI.Tee.strip_ansi()

    assert output =~ "◆ Dev Agent's Response ◆"
    assert output =~ "Final assistant response"
    assert output =~ "────────────────────────────────────────────────────────────"

    assert output =~ ~r/◆ Dev Agent's Response ◆.*Final assistant response/s

    assert_logged(~r/Dev Agent/)
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

    AI.Completion.Output.replay_conversation(state)

    assert_logged(~r/Dev Only.*hello|hello.*Dev Only/s)
  end
end

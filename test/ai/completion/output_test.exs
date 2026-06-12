defmodule AI.Completion.OutputTest do
  use Fnord.TestCase, async: true

  import ExUnit.CaptureIO

  describe "replay_conversation_as_output/1" do
    test "writes final response to STDOUT without invoking formatter when stdout is not a TTY" do
      set_config(:stdout_tty, false)
      set_config(:ui_output, UI.Output.TestStub)
      set_config(:quiet, true)

      # The formatter is only invoked when stdout is a TTY. Point it at a
      # command that would visibly mutate the output ("final" -> "finbl"), so
      # the exact-match assertion below doubles as proof it never ran.
      Util.Env.put_override("FNORD_FORMATTER", "tr 'a' 'b'")

      state = %{
        name: "Xalor",
        messages: [
          %{role: "system", content: "system"},
          %{role: "user", content: "hi"},
          %{role: "assistant", content: "final"}
        ],
        log_msgs: false,
        log_tool_calls: false
      }

      output =
        capture_io(:stdio, fn ->
          AI.Completion.Output.replay_conversation_as_output(state)
        end)

      assert output == "\nfinal\n"
      refute output =~ "Response"
      refute output =~ "Xalor"
    end
  end
end

defmodule AI.Completion.OutputTest do
  use Fnord.TestCase, async: false

  import ExUnit.CaptureIO

  describe "replay_conversation_as_output/1" do
    test "writes final response to STDOUT without invoking formatter when stdout is not a TTY" do
      # Capture and restore environment and globals for isolation
      orig_formatter = System.get_env("FNORD_FORMATTER")
      orig_ui_output = Services.Globals.get_env(:fnord, :ui_output)
      orig_quiet = Services.Globals.get_env(:fnord, :quiet)

      mocked? =
        try do
          safe_meck_new(UI, [:passthrough])
          true
        rescue
          _ -> false
        end

      if mocked? do
        :meck.expect(UI, :stdout_tty?, 0, fn -> false end)
        :meck.expect(UI, :format, 1, fn _ -> raise "formatter called" end)
      end

      on_exit(fn ->
        if mocked? do
          try do
            safe_meck_unload(UI)
          catch
            :error, {:not_mocked, UI} -> :ok
          end
        end

        case orig_formatter do
          nil -> System.delete_env("FNORD_FORMATTER")
          val -> System.put_env("FNORD_FORMATTER", val)
        end

        Services.Globals.put_env(:fnord, :ui_output, orig_ui_output)
        Services.Globals.put_env(:fnord, :quiet, orig_quiet)
      end)

      Services.Globals.put_env(:fnord, :ui_output, UI.Output.TestStub)
      Services.Globals.put_env(:fnord, :quiet, true)

      # The formatter is only called when stdout is a TTY, so we can safely set
      # it to something that would otherwise mutate output.
      System.put_env("FNORD_FORMATTER", "tr 'a' 'b'")

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

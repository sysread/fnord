defmodule UI.FormatterTest do
  # Sync: reconfigures the VM-global Logger level and asserts via
  # capture_log, which captures VM-wide log traffic - both leak across
  # concurrently running tests.
  use Fnord.TestCase, async: false

  import ExUnit.CaptureLog

  setup do
    set_log_level(:warning)
    :ok
  end

  setup do
    # Shield from any FNORD_FORMATTER in the developer's environment; tests
    # that want a formatter set their own override (see docs/dev/gotchas.md
    # #42).
    Util.Env.put_override("FNORD_FORMATTER", nil)
    :ok
  end

  setup do
    set_config(:quiet, false)

    # Tests run in a non-TTY context; override stdout_tty? so the formatter
    # is not short-circuited by the TTY check.
    set_config(:stdout_tty, true)
    :ok
  end

  describe "format_output/1" do
    test "returns input unchanged when FNORD_FORMATTER is not set" do
      Util.Env.put_override("FNORD_FORMATTER", nil)
      input = "hello world"
      assert UI.Formatter.format_output(input) == input
    end

    test "returns input unchanged when FNORD_FORMATTER is empty" do
      Util.Env.put_override("FNORD_FORMATTER", "")
      input = "hello world"
      assert UI.Formatter.format_output(input) == input
    end

    test "applies a basic shell pipeline to transform the string" do
      Util.Env.put_override("FNORD_FORMATTER", "tr a-z A-Z")
      input = "hello world"
      assert UI.Formatter.format_output(input) == "HELLO WORLD"
    end

    test "gracefully handles invalid command by logging warning and returning input" do
      Util.Env.put_override("FNORD_FORMATTER", "nonexistent_command")
      input = "test"

      log =
        capture_log(fn ->
          assert UI.Formatter.format_output(input) == input
        end)

      assert log =~ "Formatter command failed"
    end

    test "transforms multi-line ascii and preserves unicode characters" do
      Util.Env.put_override("FNORD_FORMATTER", "tr a-z A-Z")
      text = "hello\nworld\näöü"
      assert UI.Formatter.format_output(text) == "HELLO\nWORLD\näöü"
    end

    test "multi-line and unicode text unchanged when formatter unset" do
      Util.Env.put_override("FNORD_FORMATTER", nil)
      text = "hållo\nwörld\nこんにちは"
      assert UI.Formatter.format_output(text) == text
    end
  end
end

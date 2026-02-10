defmodule UI.FormatterTest do
  use Fnord.TestCase, async: false

  import ExUnit.CaptureLog

  setup do
    set_log_level(:warning)
    :ok
  end

  setup do
    original = Util.Env.get_env("FNORD_FORMATTER")
    on_exit(fn -> System.put_env("FNORD_FORMATTER", original || "") end)
    :ok
  end

  setup do
    original = Services.Globals.get_env(:fnord, :quiet)
    on_exit(fn -> Services.Globals.put_env(:fnord, :quiet, original) end)
    Services.Globals.put_env(:fnord, :quiet, false)
    :ok
  end

  describe "format_output/1" do
    test "returns input unchanged when FNORD_FORMATTER is not set" do
      System.delete_env("FNORD_FORMATTER")
      input = "hello world"
      assert UI.Formatter.format_output(input) == input
    end

    test "returns input unchanged when FNORD_FORMATTER is empty" do
      Util.Env.put_env("FNORD_FORMATTER", "")
      input = "hello world"
      assert UI.Formatter.format_output(input) == input
    end

    test "applies a basic shell pipeline to transform the string" do
      Util.Env.put_env("FNORD_FORMATTER", "tr a-z A-Z")
      input = "hello world"
      assert UI.Formatter.format_output(input) == "HELLO WORLD"
    end

    test "gracefully handles invalid command by logging warning and returning input" do
      Util.Env.put_env("FNORD_FORMATTER", "nonexistent_command")
      input = "test"

      log =
        capture_log(fn ->
          assert UI.Formatter.format_output(input) == input
        end)

      assert log =~ "Formatter command failed"
    end

    test "transforms multi-line ascii and preserves unicode characters" do
      Util.Env.put_env("FNORD_FORMATTER", "tr a-z A-Z")
      text = "hello\nworld\näöü"
      assert UI.Formatter.format_output(text) == "HELLO\nWORLD\näöü"
    end

    test "multi-line and unicode text unchanged when formatter unset" do
      System.delete_env("FNORD_FORMATTER")
      text = "hållo\nwörld\nこんにちは"
      assert UI.Formatter.format_output(text) == text
    end
  end
end

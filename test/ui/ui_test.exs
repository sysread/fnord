defmodule UI.UITest do
  import ExUnit.CaptureIO

  @moduledoc """
  Unit tests for UI.clean_detail/1 and UI.iodata?/1 functions.
  """

  use Fnord.TestCase, async: false

  alias UI

  describe "clean_detail/1" do
    test "returns empty string for nil input" do
      assert UI.clean_detail(nil) == ""
    end

    test "returns unchanged binary iodata for valid iodata input" do
      assert UI.clean_detail("hello world") == "hello world"
    end

    test "returns unchanged charlist iodata for valid iodata input" do
      assert UI.clean_detail(~c"hello") == "hello"
    end

    test "returns unchanged nested iodata for valid iodata input" do
      nested = ["foo", [32, "bar"]]
      assert UI.clean_detail(nested) == "foo bar"
    end

    test "sanitizes invalid UTF-8 binaries" do
      input = <<225, 10, 117>>
      result = UI.clean_detail(input)
      assert String.contains?(result, "�")
      assert String.contains?(result, "\n")
    end

    test "prefixes newline for multi-line binary input" do
      input = "line1\nline2\nline3"
      assert UI.clean_detail(input) == "\nline1\nline2\nline3"
    end

    test "inspects non-iodata input and returns its string representation" do
      assert UI.clean_detail(1024) == "1024"
    end

    test "prefixes newline for inspected multi-line output" do
      detail = Enum.into(1..20, %{}, fn i -> {i, List.duplicate(i, i)} end)
      result = UI.clean_detail(detail)
      assert String.starts_with?(result, "\n%{")
      assert String.contains?(result, "%{\n")
    end
  end

  describe "iodata?/1" do
    test "returns true for valid binary iodata" do
      assert UI.iodata?("hello")
    end

    test "returns true for valid integer byte" do
      assert UI.iodata?(255)
    end

    test "returns false for integer outside byte range" do
      refute UI.iodata?(-1)
      refute UI.iodata?(256)
    end

    test "returns true for empty list" do
      assert UI.iodata?([])
    end

    test "returns true for nested valid iodata list" do
      nested = [65, "BC", [67, "D"]]
      assert UI.iodata?(nested)
    end

    test "returns false for nested invalid iodata list" do
      invalid = [65, :atom, [67, "D"]]
      refute UI.iodata?(invalid)
    end

    test "returns false for improper list" do
      improper = [65 | 66]
      refute UI.iodata?(improper)
    end
  end

  describe "UI facade delegates to UI.Output via Mox" do
    setup :set_mox_from_context

    test "UI.say/1 flushes and calls puts/1 on the configured UI output" do
      expect(UI.Output.Mock, :puts, fn msg ->
        assert is_binary(msg)
        :ok
      end)

      # Stub flush to avoid unexpected calls
      stub(UI.Output.Mock, :flush, fn -> :ok end)

      UI.say("Hello")
    end

    test "UI.info/1 logs via UI.Output.log/2" do
      expect(UI.Output.Mock, :log, fn level, _msg ->
        assert level in [:info]
        :ok
      end)

      UI.info("hi")
    end

    test "UI.confirm/2 delegates to UI.Output.confirm/2" do
      expect(UI.Output.Mock, :confirm, fn msg, default ->
        assert msg == "Sure?"
        assert default == true
        true
      end)

      assert UI.confirm("Sure?", true) == true
    end

    test "UI.choose/2 returns {:error, :no_tty} when not a TTY or when quiet" do
      Settings.set_quiet(true)
      assert UI.choose("Pick", [1, 2]) == {:error, :no_tty}
    end

    test "UI.prompt/1 returns {:error, :no_tty} when not a TTY or when quiet" do
      Settings.set_quiet(true)
      assert UI.prompt("Your name?") == {:error, :no_tty}
    end

    test "UI.newline/0 delegates to UI.Output.newline/0 when not quiet" do
      Settings.set_quiet(false)
      expect(UI.Output.Mock, :newline, fn -> :ok end)
      UI.newline()
    end

    test "UI.box/2 delegates to UI.Output.box/2 and newline/0 when not quiet" do
      Settings.set_quiet(false)
      expect(UI.Output.Mock, :newline, fn -> :ok end)

      expect(UI.Output.Mock, :box, fn contents, opts ->
        assert contents == "hello"
        assert opts == [title: "T"]
        :ok
      end)

      UI.box("hello", title: "T")
    end
  end

  describe "spin/1 when registry is absent" do
    setup do
      Settings.set_quiet(false)
      # Stub Owl.Spinner.start/1 and Owl.Spinner.stop/1 to no-ops
      :meck.new(Owl.Spinner, [:no_link])
      :meck.expect(Owl.Spinner, :start, fn _ -> :ok end)
      :meck.expect(Owl.Spinner, :stop, fn _ -> :ok end)
      on_exit(fn -> :meck.unload(Owl.Spinner) end)
      :ok
    end

    test "returns :ok and does not raise when registry is not running" do
      # Ensure Owl WidgetsRegistry is not running
      assert Registry.whereis_name({Owl.WidgetsRegistry, :fnord}) in [nil, :undefined]

      capture_io(fn ->
        assert Spinner.run(fn -> {"Conversation summarized", :ok} end, "Summarizing conversation") ==
                 :ok
      end)
    end
  end
end

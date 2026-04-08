defmodule UI.Output.Production.NotificationTest do
  use Fnord.TestCase, async: false

  # CRITICAL: register on_exit BEFORE test logic, not after. If a test
  # assertion fails between :meck.new and on_exit, the cleanup never registers
  # and the mock leaks to subsequent tests. The Logger leak in particular
  # silently breaks capture_log across the whole suite (Cmd.Config.*Test
  # failures), because mocked Logger does not deliver to ExUnit's log capture.
  describe "confirm/2 behavior (non-blocking)" do
    test "returns true when default true (TTY: input 'Y\n' or non-TTY: default)" do
      on_exit(fn -> safe_meck_unload(IO) end)
      :ok = safe_meck_new(IO, [:passthrough])
      :meck.expect(IO, :gets, 1, fn "" -> "Y\n" end)

      {_stdout, _stderr} =
        capture_all(fn ->
          assert UI.Output.Production.confirm("Proceed?", true) == true
        end)
    end

    test "returns false when default false (TTY: input 'n\n' or non-TTY: default)" do
      on_exit(fn -> safe_meck_unload(IO) end)
      :ok = safe_meck_new(IO, [:passthrough])
      :meck.expect(IO, :gets, 1, fn "" -> "n\n" end)

      {_stdout, _stderr} =
        capture_all(fn ->
          assert UI.Output.Production.confirm("Proceed?", false) == false
        end)
    end
  end

  describe "basic delegates" do
    test "newline delegates to puts" do
      # Ensure UI facade is active
      orig = Services.Globals.get_env(:fnord, :quiet)
      on_exit(fn -> Services.Globals.put_env(:fnord, :quiet, orig) end)
      Settings.set_quiet(false)

      expect(UI.Output.Mock, :newline, fn -> :ok end)
      UI.newline()
      verify!()
    end

    test "box renders and prints via Owl.Box.new and puts" do
      # Ensure UI facade is active
      orig = Services.Globals.get_env(:fnord, :quiet)
      on_exit(fn -> Services.Globals.put_env(:fnord, :quiet, orig) end)
      Settings.set_quiet(false)

      on_exit(fn -> safe_meck_unload(Owl.Box) end)
      :ok = safe_meck_new(Owl.Box, [:passthrough])

      :meck.expect(Owl.Box, :new, 2, fn contents, _opts ->
        "BOX:" <> contents
      end)

      expect(UI.Output.Mock, :box, fn "hello", [] -> :ok end)
      UI.box("hello", [])

      verify!()
    end

    test "flush calls Logger.flush" do
      on_exit(fn -> safe_meck_unload(Logger) end)
      :ok = safe_meck_new(Logger, [:passthrough])

      :meck.expect(Logger, :flush, 0, fn ->
        send(self(), :logger_flushed)
        :ok
      end)

      UI.Output.Production.flush()
      assert_receive :logger_flushed
    end
  end
end

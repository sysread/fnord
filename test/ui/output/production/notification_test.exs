defmodule UI.Output.Production.NotificationTest do
  use Fnord.TestCase, async: false

  describe "confirm/2 behavior (non-blocking)" do
    test "returns true when default true (TTY: input 'Y\n' or non-TTY: default)" do
      # Stub IO.gets so that if TTY branch runs, it does not block
      :meck.new(IO, [:passthrough])
      :meck.expect(IO, :gets, 1, fn "" -> "Y\n" end)

      on_exit(fn ->
        try do
          :meck.unload(IO)
        rescue
          _ -> :ok
        end
      end)

      {_stdout, _stderr} =
        capture_all(fn ->
          assert UI.Output.Production.confirm("Proceed?", true) == true
        end)
    end

    test "returns false when default false (TTY: input 'n\n' or non-TTY: default)" do
      :meck.new(IO, [:passthrough])
      :meck.expect(IO, :gets, 1, fn "" -> "n\n" end)

      on_exit(fn ->
        try do
          :meck.unload(IO)
        rescue
          _ -> :ok
        end
      end)

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

      :meck.new(Owl.Box, [:passthrough])

      :meck.expect(Owl.Box, :new, 2, fn contents, _opts ->
        "BOX:" <> contents
      end)

      expect(UI.Output.Mock, :box, fn "hello", [] -> :ok end)
      UI.box("hello", [])

      on_exit(fn ->
        try do
          :meck.unload(Owl.Box)
        rescue
          _ -> :ok
        end
      end)

      verify!()
    end

    test "flush calls Logger.flush" do
      :meck.new(Logger, [:passthrough])

      :meck.expect(Logger, :flush, 0, fn ->
        send(self(), :logger_flushed)
        :ok
      end)

      UI.Output.Production.flush()
      assert_receive :logger_flushed

      on_exit(fn ->
        try do
          :meck.unload(Logger)
        rescue
          _ -> :ok
        end
      end)
    end
  end
end

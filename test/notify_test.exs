defmodule NotifierTest do
  use Fnord.TestCase, async: false

  describe "fallback beep" do
    test "prints bell to stderr and returns :ok" do
      {_stdout, stderr} =
        capture_all(fn ->
          assert :ok == Notifier.notify("Title", "Body", platform: :other)
        end)

      assert stderr =~ "\a"
    end
  end

  describe "linux_notify error handling" do
    setup do
      :meck.new(System, [:no_link, :passthrough, :non_strict])

      # Force a GUI session
      orig_display = Util.Env.get_env("DISPLAY")

      on_exit(fn ->
        maybe_restore_env("DISPLAY", orig_display)
        :meck.unload(System)
      end)

      Util.Env.put_env("DISPLAY", "1")

      # Only notify-send is found
      :meck.expect(System, :find_executable, fn
        "notify-send" -> "/usr/bin/notify-send"
        "dunstify" -> nil
        _ -> nil
      end)

      # Stub System.cmd for notify-send
      :meck.expect(System, :cmd, fn "notify-send", args, opts ->
        assert args == ["--urgency=critical", "--expire-time=10000", "Oops", "It failed"]
        assert opts == [stderr_to_stdout: true]
        {"nope", 1}
      end)

      :ok
    end

    test "returns error tuple when notify-send exits non-zero" do
      assert {:error, {"notify-send", 1, "nope"}} =
               Notifier.notify("Oops", "It failed", platform: :linux)
    end
  end

  describe "mac_notify error handling (osascript only)" do
    setup do
      :meck.new(System, [:no_link, :passthrough, :non_strict])
      on_exit(fn -> :meck.unload(System) end)

      # Stub System.cmd for osascript
      :meck.expect(System, :cmd, fn
        "osascript", ["-e", _script], [stderr_to_stdout: true] ->
          {"boom", 1}
      end)

      :ok
    end

    test "returns error tuple when osascript exits non-zero" do
      assert {:error, {"osascript", 1, "boom"}} =
               Notifier.notify("Oops", "It failed", platform: :mac)
    end
  end

  defp maybe_restore_env(key, nil), do: System.delete_env(key)
  defp maybe_restore_env(key, value), do: Util.Env.put_env(key, value)
end

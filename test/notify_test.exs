defmodule NotifierTest do
  # async: false - the linux test mutates DISPLAY, which is real OS
  # environment shared across the whole BEAM.
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
      # Force a GUI session so the linux path reaches the notifier binaries
      # instead of falling back to the beep.
      orig_display = Util.Env.get_env("DISPLAY")
      on_exit(fn -> maybe_restore_env("DISPLAY", orig_display) end)
      Util.Env.put_env("DISPLAY", "1")

      :ok
    end

    test "returns error tuple when notify-send exits non-zero" do
      # Only notify-send is on the PATH.
      stub(Util.Exec.Mock, :find_executable, fn
        "notify-send" -> "/usr/bin/notify-send"
        _ -> nil
      end)

      stub(Util.Exec.Mock, :cmd, fn "notify-send", args, opts ->
        assert args == ["--urgency=critical", "--expire-time=10000", "Oops", "It failed"]
        assert opts == [stderr_to_stdout: true]
        {"nope", 1}
      end)

      assert {:error, {"notify-send", 1, "nope"}} =
               Notifier.notify("Oops", "It failed", platform: :linux)
    end
  end

  describe "mac_notify error handling (osascript only)" do
    test "returns error tuple when osascript exits non-zero" do
      stub(Util.Exec.Mock, :cmd, fn "osascript", ["-e", _script], [stderr_to_stdout: true] ->
        {"boom", 1}
      end)

      assert {:error, {"osascript", 1, "boom"}} =
               Notifier.notify("Oops", "It failed", platform: :mac)
    end
  end

  defp maybe_restore_env(key, nil), do: System.delete_env(key)
  defp maybe_restore_env(key, value), do: Util.Env.put_env(key, value)
end

defmodule NotifierTest do
  use Fnord.TestCase, async: false
  import ExUnit.CaptureIO

  # -----------------------------
  # Fallback test (all OSes)
  # -----------------------------
  describe "fallback beep" do
    setup do
      # Stub System to prevent any real external calls
      :meck.new(System, [:no_link, :passthrough, :non_strict])

      # Save original GUI env vars and restore after
      orig_display = System.get_env("DISPLAY")
      orig_wayland = System.get_env("WAYLAND_DISPLAY")

      on_exit(fn ->
        restore_env("DISPLAY", orig_display)
        restore_env("WAYLAND_DISPLAY", orig_wayland)
        :meck.unload(System)
      end)

      # Clear GUI env so fallback_beep is chosen
      System.delete_env("DISPLAY")
      System.delete_env("WAYLAND_DISPLAY")

      # No notifier executables present
      :meck.expect(System, :find_executable, fn _ -> nil end)

      :ok
    end

    test "prints bell to stderr and returns :ok when no notifier is available" do
      stderr =
        capture_io(:stderr, fn ->
          assert :ok == Notifier.notify("Title", "Body")
        end)

      assert stderr =~ "\a"
    end
  end

  # ----------------------------------
  # Linux-specific error propagation
  # ----------------------------------
  if match?({:unix, :linux}, :os.type()) do
    describe "linux_notify error handling" do
      setup do
        :meck.new(System, [:no_link, :passthrough, :non_strict])

        # Force a GUI session
        orig_display = System.get_env("DISPLAY")

        on_exit(fn ->
          restore_env("DISPLAY", orig_display)
          :meck.unload(System)
        end)

        System.put_env("DISPLAY", "1")

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
        assert {:error, {"notify-send", 1, "nope"}} = Notifier.notify("Oops", "It failed")
      end
    end
  end

  # ---------------------------------
  # macOS-specific error propagation
  # ---------------------------------
  if match?({:unix, :darwin}, :os.type()) do
    describe "mac_notify error handling" do
      setup do
        :meck.new(System, [:no_link, :passthrough, :non_strict])
        on_exit(fn -> :meck.unload(System) end)

        # Only terminal-notifier is found
        :meck.expect(System, :find_executable, fn
          "terminal-notifier" -> "/usr/local/bin/terminal-notifier"
          "osascript" -> nil
          _ -> nil
        end)

        # Stub System.cmd for terminal-notifier
        :meck.expect(System, :cmd, fn "terminal-notifier", args, opts ->
          assert args == ["-title", "Oops", "-message", "It failed", "-group", "fnord"]
          assert opts == [stderr_to_stdout: true]
          {"boom", 1}
        end)

        :ok
      end

      test "returns error tuple when terminal-notifier exits non-zero" do
        assert {:error, {"terminal-notifier", 1, "boom"}} = Notifier.notify("Oops", "It failed")
      end
    end
  end

  # ----------------------
  # Helper functions
  # ----------------------
  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end

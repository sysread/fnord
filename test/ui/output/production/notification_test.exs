defmodule UI.Output.Production.NotificationTest do
  use Fnord.TestCase, async: true

  import ExUnit.CaptureIO

  # These tests exercise UI.Output.Production directly (not through the UI
  # facade, which routes to UI.Output.Mock in tests). Production writes via
  # UI.Queue, and the queue's exec runs IO in the queue process - so output
  # lands on the *queue's* group leader, not the test's. Each test that
  # asserts real output starts a fresh UI.Queue inside capture_io so the
  # queue (and any task it spawns) inherits the capture device. start_link
  # re-registers the tree's queue instance, which is what lets Production's
  # hardcoded UI.Queue.instance() resolve to the captured queue.

  describe "confirm/2 on a TTY" do
    setup do
      # Production.confirm gates on UI.is_tty?, which honors the tree-scoped
      # :is_tty override.
      set_config(:is_tty, true)
      :ok
    end

    test "parses 'Y' as true" do
      capture_io([input: "Y\n"], fn ->
        capture_io(:stderr, fn ->
          {:ok, _} = UI.Queue.start_link([])
          assert UI.Output.Production.confirm("Proceed?", false) == true
        end)
      end)
    end

    test "parses anything else as the default" do
      capture_io([input: "n\n"], fn ->
        capture_io(:stderr, fn ->
          {:ok, _} = UI.Queue.start_link([])
          assert UI.Output.Production.confirm("Proceed?", false) == false
        end)
      end)
    end

    test "prompt shows the default in uppercase" do
      stderr =
        capture_io(:stderr, fn ->
          capture_io([input: "y\n"], fn ->
            {:ok, _} = UI.Queue.start_link([])
            assert UI.Output.Production.confirm("Proceed?", true) == true
          end)
        end)

      assert stderr =~ "Proceed? (Y/n)"
    end
  end

  describe "confirm/2 without a TTY" do
    setup do
      set_config(:is_tty, false)
      :ok
    end

    test "returns the default without prompting" do
      assert UI.Output.Production.confirm("Proceed?", true) == true
      assert UI.Output.Production.confirm("Proceed?", false) == false
    end
  end

  describe "basic delegates" do
    test "newline emits a blank line through the queue" do
      output =
        capture_io(fn ->
          {:ok, _} = UI.Queue.start_link([])
          assert UI.Output.Production.newline() == :ok
        end)

      assert output == "\n"
    end

    test "box renders contents and title via Owl.Box" do
      output =
        capture_io(fn ->
          {:ok, _} = UI.Queue.start_link([])
          assert UI.Output.Production.box("hello", title: "T") == :ok
        end)

      assert output =~ "hello"
      assert output =~ "T"
    end

    test "flush returns :ok" do
      assert UI.Output.Production.flush() == :ok
    end
  end
end

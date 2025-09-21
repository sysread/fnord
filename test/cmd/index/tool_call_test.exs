defmodule Cmd.Index.ToolCallTest do
  use Fnord.TestCase

  describe "run_as_tool_call/1" do
    setup do
      # Prepare a minimal project so run_as_tool_call can find the project root
      mock_project("test_project")

      :ok
    end

    test "restores the quiet flag after tool call when opts quiet true" do
      # Set initial quiet to false to simulate a non-quiet environment
      Settings.set_quiet(false)
      assert Services.Globals.get_env(:fnord, :quiet) == false

      # Invoke the tool call, which temporarily sets quiet mode
      _ = Cmd.Index.run_as_tool_call(%{quiet: true})

      # After tool call, the quiet flag should be restored to its original value
      assert Services.Globals.get_env(:fnord, :quiet) == false
    end

    test "preserves the quiet flag when opts quiet false" do
      # Set initial quiet to true to simulate a quiet environment
      Settings.set_quiet(true)
      assert Services.Globals.get_env(:fnord, :quiet) == true

      # Invoke the tool call without enabling quiet mode
      _ = Cmd.Index.run_as_tool_call(%{quiet: false})

      # After tool call, the quiet flag should remain unchanged
      assert Services.Globals.get_env(:fnord, :quiet) == true
    end
  end
end

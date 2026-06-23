defmodule Cmd.Index.ToolCallTest do
  use Fnord.TestCase, async: false

  defmodule BlockingIndexer do
    @behaviour Indexer

    @impl Indexer
    def get_embeddings(content) do
      parent = Services.Globals.get_env(:fnord, :blocking_indexer_parent)

      send(parent, {:embedding_started, self(), UI.quiet?(), UI.colorize?(), content})

      receive do
        :continue -> {:ok, List.duplicate(0.1, 384)}
      end
    end

    @impl Indexer
    def get_summary(_file, _content), do: {:ok, "summary"}
  end

  describe "run_as_tool_call/1" do
    setup do
      # Prepare a minimal project so run_as_tool_call can find the project root
      mock_project("test_project")

      :ok
    end

    test "does not flip the global quiet flag while tool-call indexing is running" do
      project = mock_git_project("tool_call_quiet_project")
      mock_source_file(project, "file1.txt", "file1")

      original_indexer = Services.Globals.get_env(:fnord, :indexer)
      Services.Globals.put_env(:fnord, :indexer, BlockingIndexer)
      Services.Globals.put_env(:fnord, :blocking_indexer_parent, self())

      on_exit(fn ->
        Services.Globals.put_env(:fnord, :indexer, original_indexer)
        Services.Globals.delete_env(:fnord, :blocking_indexer_parent)
      end)

      Settings.set_quiet(false)
      Services.Globals.put_env(:fnord, :is_tty, true)

      task =
        Task.async(fn ->
          Cmd.Index.run_as_tool_call(%{project: project.name, yes: true, quiet: true})
        end)

      assert_receive {:embedding_started, indexer_pid, false, true, _content}
      assert Services.Globals.get_env(:fnord, :quiet) == false

      send(indexer_pid, :continue)
      assert Task.await(task) == :ok
      assert Services.Globals.get_env(:fnord, :quiet) == false
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

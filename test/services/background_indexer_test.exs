defmodule Services.BackgroundIndexerTest do
  use Fnord.TestCase

  alias Services.BackgroundIndexer
  alias Store.Project.Entry

  # Define a stub indexer that records processed file paths
  defmodule StubIndexer do
    use Agent
    @behaviour Indexer

    # Start an Agent to track processed files
    def start_link(_opts) do
      Agent.start_link(fn -> MapSet.new() end, name: __MODULE__)
    end

    # Reset the Agent state
    def reset do
      Agent.update(__MODULE__, fn _ -> MapSet.new() end)
    end

    # Check if a file path has been processed
    def processed?(file), do: Agent.get(__MODULE__, &MapSet.member?(&1, file))

    @impl Indexer
    def get_embeddings(_), do: {:ok, []}

    @impl Indexer
    def get_summary(file, _content) do
      Agent.update(__MODULE__, &MapSet.put(&1, file))
      {:ok, "summary"}
    end

    @impl Indexer
    def get_outline(file, _content) do
      Agent.update(__MODULE__, &MapSet.put(&1, file))
      {:ok, "outline"}
    end
  end

  setup do
    # Configure Indexer to use our stub implementation
    Services.Globals.put_env(:fnord, :indexer, StubIndexer)
    {:ok, _} = StubIndexer.start_link([])
    StubIndexer.reset()

    # Prepare fake entry paths
    entries = [
      %Entry{file: "a.ex"},
      %Entry{file: "b.ex"}
    ]

    {:ok, entries: entries}
  end

  test "indexes stale entries then stops cleanly", %{entries: entries} do
    # Start background indexer with fake entries
    {:ok, pid} = BackgroundIndexer.start_link(files: entries)
    # Monitor for termination when queue is processed
    ref = Process.monitor(pid)
    # Wait for the GenServer to finish processing and stop normally
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    # Assert both entries were processed by the stub indexer
    assert StubIndexer.processed?("a.ex")
    assert StubIndexer.processed?("b.ex")
  end
end

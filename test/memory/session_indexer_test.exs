defmodule Memory.SessionIndexerTest do
  use Fnord.TestCase, async: false

  test "summarize conversation extracts user and assistant message" do
    msgs = [
      AI.Util.system_msg("ignored system msg"),
      AI.Util.user_msg("Hello there, I need help with X"),
      AI.Util.assistant_msg("<think>internal reasoning</think>"),
      AI.Util.assistant_msg("I can help with X by doing Y")
    ]

    summary =
      msgs
      |> Services.MemoryIndexer.summarize_conversation()

    assert String.contains?(summary, "Hello there")
    assert String.contains?(summary, "I can help with X")
  end

  test "process_conversation handles empty memory list gracefully" do
    mock_project("si-test")
    ctx = mock_conversation()

    conv = ctx.conversation
    # Ensure the MemoryIndexer service is running for this test. Start it
    # idempotently and register a teardown to stop it when the test exits.
    case Process.whereis(Services.MemoryIndexer) do
      nil ->
        case Services.MemoryIndexer.start_link(auto_scan: false) do
          {:ok, _pid} ->
            on_exit(fn ->
              pid = Process.whereis(Services.MemoryIndexer)

              # Stop the memory indexer only if it's still alive. Guard the stop
              # call to avoid races in CI where the server may have already
              # terminated between the lookup and the stop call.
              if is_pid(pid) and Process.alive?(pid) do
                try do
                  GenServer.stop(Services.MemoryIndexer)
                rescue
                  _ -> :ok
                end
              end
            end)

          _ ->
            :ok
        end

      _pid ->
        :ok
    end

    assert :ok = Services.MemoryIndexer.process_sync(conv)
  end
end

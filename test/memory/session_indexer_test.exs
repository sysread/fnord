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
        case Services.MemoryIndexer.start_link([]) do
          {:ok, _pid} ->
            on_exit(fn ->
              if Process.whereis(Services.MemoryIndexer),
                do: GenServer.stop(Services.MemoryIndexer)
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

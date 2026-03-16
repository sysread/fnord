defmodule Memory.SessionIndexerTest do
  use Fnord.TestCase, async: false

  defp stop_memory_indexer do
    pid = Process.whereis(Services.MemoryIndexer)

    case is_pid(pid) and Process.alive?(pid) do
      true ->
        try do
          GenServer.stop(Services.MemoryIndexer)
        catch
          :exit, _ -> :ok
        end

      false ->
        :ok
    end
  end

  defp start_memory_indexer(opts \\ [auto_scan: false]) do
    case Process.whereis(Services.MemoryIndexer) do
      nil ->
        case Services.MemoryIndexer.start_link(opts) do
          {:ok, _pid} ->
            :ok

          {:error, {:already_started, _pid}} ->
            :ok
        end

      _pid ->
        :ok
    end
  end

  defp stale_lock_dir(path) do
    File.mkdir_p!(path)
    File.touch!(path, System.os_time(:second) - 3600)
  end

  defp write_live_owner_file(lock_dir, pid \\ self()) do
    File.mkdir_p!(lock_dir)

    owner_path = Path.join(lock_dir, "owner")

    File.write!(owner_path, "pid: #{inspect(pid)}\nat: #{System.system_time(:millisecond)}")
  end

  defp restart_memory_indexer(opts) do
    stop_memory_indexer()
    on_exit(fn -> stop_memory_indexer() end)
    start_memory_indexer(opts)
  end

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
    start_memory_indexer()
    on_exit(fn -> stop_memory_indexer() end)

    assert :ok = Services.MemoryIndexer.process_sync(conv)
  end

  test "startup removes orphaned stale memory lock dirs" do
    stop_memory_indexer()

    project = mock_project("si-lock-orphan")
    memory_dir = Path.join(project.store_path, "memory")
    lock_dir = Path.join(memory_dir, "orphan.json.lock")

    stale_lock_dir(lock_dir)
    restart_memory_indexer(auto_scan: false)

    refute File.exists?(lock_dir)
  end

  test "startup keeps stale memory lock dirs when target json exists" do
    stop_memory_indexer()

    project = mock_project("si-lock-present")
    memory_dir = Path.join(project.store_path, "memory")
    json_path = Path.join(memory_dir, "present.json")
    lock_dir = Path.join(memory_dir, "present.json.lock")

    File.mkdir_p!(memory_dir)
    File.write!(json_path, "{}")
    stale_lock_dir(lock_dir)
    restart_memory_indexer(auto_scan: false)

    assert File.dir?(lock_dir)
  end

  test "startup keeps stale memory lock dirs with live owner pid" do
    stop_memory_indexer()

    project = mock_project("si-lock-live-owner")
    memory_dir = Path.join(project.store_path, "memory")
    lock_dir = Path.join(memory_dir, "live-owner.json.lock")

    stale_lock_dir(lock_dir)
    write_live_owner_file(lock_dir)
    restart_memory_indexer(auto_scan: false)

    assert File.dir?(lock_dir)
  end
end

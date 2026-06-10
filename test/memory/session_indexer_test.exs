defmodule Memory.SessionIndexerTest do
  use Fnord.TestCase, async: true

  defp stale_lock_dir(path) do
    File.mkdir_p!(path)
    File.touch!(path, System.os_time(:second) - 3600)
  end

  defp released_lock_dir(memory_dir, basename) do
    Path.join(memory_dir, "#{basename}.json.lock.released.test")
  end

  defp write_live_owner_file(lock_dir, pid \\ self()) do
    File.mkdir_p!(lock_dir)

    owner_path = Path.join(lock_dir, "owner")

    File.write!(owner_path, "pid: #{inspect(pid)}\nat: #{System.system_time(:millisecond)}")
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
    {:ok, _} = Services.MemoryIndexer.start_link(auto_scan: false)

    assert :ok = Services.MemoryIndexer.process_sync(conv)
  end

  test "startup removes orphaned stale memory lock dirs" do
    project = mock_project("si-lock-orphan")
    memory_dir = Path.join(project.store_path, "memory")
    lock_dir = Path.join(memory_dir, "orphan.json.lock")

    stale_lock_dir(lock_dir)
    {:ok, _} = Services.MemoryIndexer.start_link(auto_scan: false)

    refute File.exists?(lock_dir)
  end

  test "startup removes orphaned stale released memory lock dirs" do
    project = mock_project("si-lock-released-orphan")
    memory_dir = Path.join(project.store_path, "memory")
    lock_dir = released_lock_dir(memory_dir, "orphan")

    stale_lock_dir(lock_dir)
    {:ok, _} = Services.MemoryIndexer.start_link(auto_scan: false)

    refute File.exists?(lock_dir)
  end

  test "startup keeps stale memory lock dirs when target json exists" do
    project = mock_project("si-lock-present")
    memory_dir = Path.join(project.store_path, "memory")
    json_path = Path.join(memory_dir, "present.json")
    lock_dir = Path.join(memory_dir, "present.json.lock")

    File.mkdir_p!(memory_dir)
    File.write!(json_path, "{}")
    stale_lock_dir(lock_dir)
    {:ok, _} = Services.MemoryIndexer.start_link(auto_scan: false)

    assert File.dir?(lock_dir)
  end

  test "startup keeps stale released memory lock dirs when target json exists" do
    project = mock_project("si-lock-released-present")
    memory_dir = Path.join(project.store_path, "memory")
    json_path = Path.join(memory_dir, "present.json")
    lock_dir = released_lock_dir(memory_dir, "present")

    File.mkdir_p!(memory_dir)
    File.write!(json_path, "{}")
    stale_lock_dir(lock_dir)
    {:ok, _} = Services.MemoryIndexer.start_link(auto_scan: false)

    assert File.dir?(lock_dir)
  end

  test "startup keeps stale released memory lock dirs with live owner pid" do
    project = mock_project("si-lock-released-live-owner")
    memory_dir = Path.join(project.store_path, "memory")
    lock_dir = released_lock_dir(memory_dir, "live-owner")

    stale_lock_dir(lock_dir)
    write_live_owner_file(lock_dir)
    {:ok, _} = Services.MemoryIndexer.start_link(auto_scan: false)

    assert File.dir?(lock_dir)
  end

  test "startup keeps stale memory lock dirs with live owner pid" do
    project = mock_project("si-lock-live-owner")
    memory_dir = Path.join(project.store_path, "memory")
    lock_dir = Path.join(memory_dir, "live-owner.json.lock")

    stale_lock_dir(lock_dir)
    write_live_owner_file(lock_dir)
    {:ok, _} = Services.MemoryIndexer.start_link(auto_scan: false)

    assert File.dir?(lock_dir)
  end
end

defmodule Store.Project.NotesLockTest do
  use Fnord.TestCase

  alias Store.Project.Notes

  describe "with_flock/2 exclusive lock" do
    setup do
      project = mock_project("notes_lock_exclusive")
      File.mkdir_p!(project.store_path)
      {:ok, project: project}
    end

    test "acquires and releases lock on success" do
      {:ok, path} = Notes.file_path()
      lock_path = path <> ".lock"
      refute File.exists?(lock_path)

      assert :ok =
               Notes.with_flock(:exclusive, fn ->
                 assert File.exists?(lock_path)
                 :ok
               end)

      refute File.exists?(lock_path)
    end

    test "releases lock even if function raises" do
      {:ok, path} = Notes.file_path()
      lock_path = path <> ".lock"

      assert_raise RuntimeError, fn ->
        Notes.with_flock(:exclusive, fn ->
          raise "boom"
        end)
      end

      refute File.exists?(lock_path)
    end
  end

  describe "with_flock/2 shared lock" do
    setup do
      project = mock_project("notes_lock_shared")
      File.mkdir_p!(project.store_path)
      {:ok, project: project}
    end

    test "waits for exclusive lock to be released" do
      {:ok, path} = Notes.file_path()
      lock_path = path <> ".lock"
      latch = self()

      Task.start(fn ->
        Notes.with_flock(:exclusive, fn ->
          send(latch, :locked)
          Process.sleep(50)
          :ok
        end)
      end)

      assert_receive :locked, 100
      assert File.exists?(lock_path)

      start_time = System.monotonic_time(:millisecond)
      assert :shared = Notes.with_flock(:shared, fn -> :shared end)
      duration = System.monotonic_time(:millisecond) - start_time
      assert duration >= 50
      refute File.exists?(lock_path)
    end
  end
end

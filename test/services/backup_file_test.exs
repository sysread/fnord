defmodule Services.BackupFileTest do
  use Fnord.TestCase, async: false

  setup do
    project = mock_project("backup-server-test")
    File.mkdir_p!(project.source_root)

    # Reset backup server state for clean tests
    Services.BackupFile.reset()

    {:ok, project: project}
  end

  describe "start_link/0" do
    test "positive path" do
      # Server should already be started in test setup
      assert Process.whereis(Services.BackupFile) != nil
    end
  end

  describe "create_backup/1" do
    test "positive path creates backup with correct naming", %{project: project} do
      # Create test file
      test_file = Path.join(project.source_root, "test.txt")
      original_content = "test content"
      File.write!(test_file, original_content)

      assert {:ok, backup_path} = Services.BackupFile.create_backup(test_file)

      expected_backup = "#{test_file}.0.0.bak"
      assert backup_path == expected_backup
      assert File.exists?(expected_backup)
      assert File.read!(expected_backup) == original_content
    end

    test "increments change counter for same file", %{project: project} do
      # Create test file
      test_file = Path.join(project.source_root, "test.txt")
      File.write!(test_file, "content")

      # First backup
      assert {:ok, backup1} = Services.BackupFile.create_backup(test_file)
      assert backup1 == "#{test_file}.0.0.bak"

      # Second backup
      assert {:ok, backup2} = Services.BackupFile.create_backup(test_file)
      assert backup2 == "#{test_file}.0.1.bak"

      # Third backup
      assert {:ok, backup3} = Services.BackupFile.create_backup(test_file)
      assert backup3 == "#{test_file}.0.2.bak"

      assert File.exists?(backup1)
      assert File.exists?(backup2)
      assert File.exists?(backup3)
    end

    test "increments global counter when existing backup found", %{project: project} do
      # Create test file
      test_file = Path.join(project.source_root, "test.txt")
      File.write!(test_file, "new content")

      # Create existing backup from "previous session"
      existing_backup = "#{test_file}.0.5.bak"
      File.write!(existing_backup, "old content")

      assert {:ok, backup_path} = Services.BackupFile.create_backup(test_file)

      # Should use global counter 1
      expected_backup = "#{test_file}.1.0.bak"
      assert backup_path == expected_backup
      assert File.exists?(expected_backup)
      assert File.read!(expected_backup) == "new content"

      # Original backup should still exist
      assert File.exists?(existing_backup)
      assert File.read!(existing_backup) == "old content"
    end

    test "handles multiple existing backups correctly", %{project: project} do
      # Create test file
      test_file = Path.join(project.source_root, "test.txt")
      File.write!(test_file, "current content")

      # Create multiple existing backups with different global counters
      File.write!("#{test_file}.0.0.bak", "backup 0.0")
      File.write!("#{test_file}.0.3.bak", "backup 0.3")
      File.write!("#{test_file}.2.1.bak", "backup 2.1")
      File.write!("#{test_file}.1.0.bak", "backup 1.0")

      assert {:ok, backup_path} = Services.BackupFile.create_backup(test_file)

      # Should use global counter 3 (max 2 + 1)
      expected_backup = "#{test_file}.3.0.bak"
      assert backup_path == expected_backup
      assert File.exists?(expected_backup)
      assert File.read!(expected_backup) == "current content"
    end

    test "different files get independent counters", %{project: project} do
      # Create two test files
      file1 = Path.join(project.source_root, "file1.txt")
      file2 = Path.join(project.source_root, "file2.txt")
      File.write!(file1, "content 1")
      File.write!(file2, "content 2")

      assert {:ok, backup1} = Services.BackupFile.create_backup(file1)
      assert {:ok, backup2} = Services.BackupFile.create_backup(file2)

      assert backup1 == "#{file1}.0.0.bak"
      assert backup2 == "#{file2}.0.0.bak"
      assert File.read!(backup1) == "content 1"
      assert File.read!(backup2) == "content 2"
    end

    test "fails when source file does not exist", %{project: project} do
      nonexistent_file = Path.join(project.source_root, "nonexistent.txt")

      assert {:error, :source_file_not_found} =
               Services.BackupFile.create_backup(nonexistent_file)
    end
  end

  describe "get_session_backups/0" do
    test "positive path returns session backup files in reverse chronological order", %{
      project: project
    } do
      # Initially empty
      assert Services.BackupFile.get_session_backups() == []

      # Create backups for different files
      file1 = Path.join(project.source_root, "file1.txt")
      file2 = Path.join(project.source_root, "file2.txt")
      File.write!(file1, "content 1")
      File.write!(file2, "content 2")

      assert {:ok, backup1} = Services.BackupFile.create_backup(file1)
      assert Services.BackupFile.get_session_backups() == [backup1]

      assert {:ok, backup2} = Services.BackupFile.create_backup(file2)
      assert Services.BackupFile.get_session_backups() == [backup2, backup1]

      # Create another backup of file1
      assert {:ok, backup3} = Services.BackupFile.create_backup(file1)
      session_backups = Services.BackupFile.get_session_backups()
      assert length(session_backups) == 3
      # Most recent backup should be first
      assert List.first(session_backups) == backup3
      assert backup2 in session_backups
      assert backup1 in session_backups
    end

    test "excludes backups from previous sessions", %{project: project} do
      # Create a file and simulate existing backup from "previous session"
      test_file = Path.join(project.source_root, "test.txt")
      File.write!(test_file, "content")

      # Pre-existing backup file (not tracked by current session)
      existing_backup = "#{test_file}.0.5.bak"
      File.write!(existing_backup, "old session content")

      # Current session should start empty
      assert Services.BackupFile.get_session_backups() == []

      # Create backup in current session
      assert {:ok, session_backup} = Services.BackupFile.create_backup(test_file)

      # Should only return the current session backup, not the pre-existing one
      assert Services.BackupFile.get_session_backups() == [session_backup]
      assert session_backup != existing_backup

      # Verify the pre-existing backup still exists but isn't tracked
      assert File.exists?(existing_backup)
      refute Enum.member?(Services.BackupFile.get_session_backups(), existing_backup)
    end
  end

  describe "reset/0" do
    test "positive path clears state but respects existing backup files", %{project: project} do
      # Create some backups
      test_file = Path.join(project.source_root, "test.txt")
      File.write!(test_file, "content")

      Services.BackupFile.create_backup(test_file)
      Services.BackupFile.create_backup(test_file)

      assert length(Services.BackupFile.get_session_backups()) == 2

      # Reset should clear state
      Services.BackupFile.reset()
      assert Services.BackupFile.get_session_backups() == []

      # Next backup should detect existing files and increment global counter
      # Since we already have *.0.0.bak and *.0.1.bak files, it should use global counter 1
      assert {:ok, backup} = Services.BackupFile.create_backup(test_file)
      assert backup == "#{test_file}.1.0.bak"
    end

    test "clears state allowing fresh start in clean directory", %{project: project} do
      # Create backup in a new, clean file
      test_file = Path.join(project.source_root, "fresh_file.txt")
      File.write!(test_file, "content")

      # Reset server state first 
      Services.BackupFile.reset()

      # Should start from 0.0 for a file with no existing backups
      assert {:ok, backup} = Services.BackupFile.create_backup(test_file)
      assert backup == "#{test_file}.0.0.bak"
    end
  end

  describe "offer_cleanup/0" do
    test "skips cleanup when no backup files exist" do
      # Mock UI to capture calls (but none should be made)
      :meck.new(UI, [:passthrough])

      Services.BackupFile.offer_cleanup()

      # Verify no UI calls were made
      assert :meck.called(UI, :info, :_) == false

      :meck.unload(UI)
    end

    test "offers cleanup when backup files exist and user accepts", %{project: project} do
      # Create some backup files
      test_file1 = Path.join(project.source_root, "file1.txt")
      test_file2 = Path.join(project.source_root, "file2.txt")
      File.write!(test_file1, "content 1")
      File.write!(test_file2, "content 2")

      {:ok, backup1} = Services.BackupFile.create_backup(test_file1)
      {:ok, backup2} = Services.BackupFile.create_backup(test_file2)

      # Verify backup files exist
      assert File.exists?(backup1)
      assert File.exists?(backup2)

      # Mock UI functions
      :meck.new(UI, [:passthrough])
      :meck.expect(UI, :warning_banner, fn _msg -> :ok end)
      :meck.expect(UI, :say, fn _msg -> :ok end)
      :meck.expect(UI, :info, fn _msg -> :ok end)
      :meck.expect(UI, :confirm, fn _prompt -> true end)

      Services.BackupFile.offer_cleanup()

      # Verify UI calls were made
      assert :meck.called(UI, :warning_banner, ["Backup files were created during this session"])
      # The backup files are listed in chronological order (oldest first) due to Enum.reverse()
      assert :meck.called(UI, :say, [
               "- #{project_path(project, backup1)}\n- #{project_path(project, backup2)}"
             ])

      assert :meck.called(UI, :confirm, ["Would you like to delete these backup files?"])

      # Verify backup files were deleted
      refute File.exists?(backup1)
      refute File.exists?(backup2)

      :meck.unload(UI)
    end

    test "retains backup files when user declines", %{project: project} do
      # Create a backup file
      test_file = Path.join(project.source_root, "file.txt")
      File.write!(test_file, "content")

      {:ok, backup_file} = Services.BackupFile.create_backup(test_file)
      assert File.exists?(backup_file)

      # Mock UI functions - user declines deletion
      :meck.new(UI, [:passthrough])
      :meck.expect(UI, :warning_banner, fn _msg -> :ok end)
      :meck.expect(UI, :say, fn _msg -> :ok end)
      :meck.expect(UI, :confirm, fn _prompt -> false end)

      Services.BackupFile.offer_cleanup()

      # Verify UI calls were made
      assert :meck.called(UI, :warning_banner, ["Backup files were created during this session"])
      assert :meck.called(UI, :say, ["- #{project_path(project, backup_file)}"])
      assert :meck.called(UI, :confirm, ["Would you like to delete these backup files?"])

      assert :meck.called(UI, :say, [
               "_Backup files not deleted. They may be removed at your convenience._"
             ])

      # Verify backup file still exists
      assert File.exists?(backup_file)

      :meck.unload(UI)
    end

    test "handles partial deletion failures gracefully", %{project: project} do
      # Create backup files
      test_file = Path.join(project.source_root, "file.txt")
      File.write!(test_file, "content")

      {:ok, backup_file} = Services.BackupFile.create_backup(test_file)
      assert File.exists?(backup_file)

      # Mock UI functions
      :meck.new(UI, [:passthrough])
      :meck.expect(UI, :warning_banner, fn _msg -> :ok end)
      :meck.expect(UI, :say, fn _msg -> :ok end)
      :meck.expect(UI, :warn, fn _msg1, _msg2 -> :ok end)
      :meck.expect(UI, :debug, fn _msg1, _msg2 -> :ok end)
      :meck.expect(UI, :confirm, fn _prompt -> true end)

      # Mock File.rm to simulate file failing to delete
      :meck.new(File, [:passthrough])
      :meck.expect(File, :rm, fn _path -> {:error, :eacces} end)

      Services.BackupFile.offer_cleanup()

      # Verify UI calls were made
      assert :meck.called(UI, :warning_banner, ["Backup files were created during this session"])
      assert :meck.called(UI, :say, ["- #{project_path(project, backup_file)}"])
      assert :meck.called(UI, :confirm, ["Would you like to delete these backup files?"])

      :meck.unload(UI)
      :meck.unload(File)
    end

    test "shows nested relative paths in cleanup summary with dotted syntax", %{project: project} do
      # Prepare a nested file
      nested_dir = Path.join(project.source_root, "nested/dir")
      File.mkdir_p!(nested_dir)
      file = Path.join(nested_dir, "file.txt")
      File.write!(file, "hello")

      # Create three backups to generate a 0..2 range
      Enum.each(1..3, fn _ -> Services.BackupFile.create_backup(file) end)

      # Mock UI to capture the summary and decline deletion
      :meck.new(UI, [:passthrough])
      :meck.expect(UI, :warning_banner, fn _ -> :ok end)

      :meck.expect(UI, :say, fn msg ->
        send(self(), {:say, msg})
        :ok
      end)

      :meck.expect(UI, :confirm, fn _ -> false end)

      Services.BackupFile.offer_cleanup()

      # Assert exactly one summary line with nested/dir prefix and dotted range
      assert_received {:say, summary}
      assert summary == "- nested/dir/file.txt.0.0..2.bak"

      :meck.unload(UI)
    end
  end

  describe "is_backup_file?/1" do
    test "returns true for valid backup files" do
      assert Services.BackupFile.is_backup_file?("file.txt.0.0.bak")
      assert Services.BackupFile.is_backup_file?("file.txt.123.456.bak")
      assert Services.BackupFile.is_backup_file?("/path/to/file.txt.1.2.bak")
      assert Services.BackupFile.is_backup_file?("../relative/path/file.ex.99.0.bak")
    end

    test "returns false for invalid backup files" do
      refute Services.BackupFile.is_backup_file?("file.txt")
      refute Services.BackupFile.is_backup_file?("file.txt.bak")
      refute Services.BackupFile.is_backup_file?("file.txt.0.bak")
      refute Services.BackupFile.is_backup_file?("file.txt.bak.0.0")
      refute Services.BackupFile.is_backup_file?("file.txt.a.0.bak")
      refute Services.BackupFile.is_backup_file?("file.txt.0.b.bak")
      refute Services.BackupFile.is_backup_file?("file.txt.0.0.backup")
    end
  end

  describe "is_session_backup?/1" do
    test "returns true for backups created in current session", %{project: project} do
      test_file = Path.join(project.source_root, "test.txt")
      File.write!(test_file, "content")

      {:ok, backup_path} = Services.BackupFile.create_backup(test_file)

      assert Services.BackupFile.is_session_backup?(backup_path)
      assert Services.BackupFile.is_session_backup?(Path.relative_to_cwd(backup_path))
    end

    test "returns false for backups not in current session", %{project: project} do
      test_file = Path.join(project.source_root, "test.txt")
      File.write!(test_file, "content")

      # Create an existing backup file manually (simulating previous session)
      existing_backup = "#{test_file}.0.0.bak"
      File.write!(existing_backup, "old content")

      refute Services.BackupFile.is_session_backup?(existing_backup)
    end

    test "returns false for non-backup files" do
      refute Services.BackupFile.is_session_backup?("regular_file.txt")
      refute Services.BackupFile.is_session_backup?("file.bak")
    end

    test "handles errors gracefully when project not available" do
      # Mock Store.get_project to return error
      :meck.new(Store, [:passthrough])
      :meck.expect(Store, :get_project, fn -> {:error, :no_project} end)

      refute Services.BackupFile.is_session_backup?("any_file.0.0.bak")

      :meck.unload(Store)
    end
  end

  describe "describe_backup/1" do
    test "returns backup description for session backups", %{project: project} do
      test_file = Path.join(project.source_root, "test.txt")
      File.write!(test_file, "content")

      {:ok, backup_path} = Services.BackupFile.create_backup(test_file)

      assert Services.BackupFile.describe_backup(backup_path) ==
               "[fnord backup file (created this session)]"
    end

    test "returns backup description for non-session backups", %{project: project} do
      test_file = Path.join(project.source_root, "test.txt")
      File.write!(test_file, "content")

      # Create an existing backup file manually (simulating previous session)
      existing_backup = "#{test_file}.0.0.bak"
      File.write!(existing_backup, "old content")

      assert Services.BackupFile.describe_backup(existing_backup) == "[fnord backup file]"
    end

    test "returns nil for non-backup files" do
      assert Services.BackupFile.describe_backup("regular_file.txt") == nil
      assert Services.BackupFile.describe_backup("file.bak") == nil
      assert Services.BackupFile.describe_backup("file.0.bak") == nil
    end
  end

  defp project_path(project, file) do
    Path.relative_to(file, project.source_root)
  end
end

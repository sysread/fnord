defmodule BackupFileServerTest do
  use Fnord.TestCase

  setup do
    project = mock_project("backup-server-test")
    File.mkdir_p!(project.source_root)

    # Reset backup server state for clean tests
    BackupFileServer.reset()

    {:ok, project: project}
  end

  describe "start_link/0" do
    test "positive path" do
      # Server should already be started in test setup
      assert Process.whereis(BackupFileServer) != nil
    end
  end

  describe "create_backup/1" do
    test "positive path creates backup with correct naming", %{project: project} do
      # Create test file
      test_file = Path.join(project.source_root, "test.txt")
      original_content = "test content"
      File.write!(test_file, original_content)

      assert {:ok, backup_path} = BackupFileServer.create_backup(test_file)

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
      assert {:ok, backup1} = BackupFileServer.create_backup(test_file)
      assert backup1 == "#{test_file}.0.0.bak"

      # Second backup
      assert {:ok, backup2} = BackupFileServer.create_backup(test_file)
      assert backup2 == "#{test_file}.0.1.bak"

      # Third backup
      assert {:ok, backup3} = BackupFileServer.create_backup(test_file)
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

      assert {:ok, backup_path} = BackupFileServer.create_backup(test_file)

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

      assert {:ok, backup_path} = BackupFileServer.create_backup(test_file)

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

      assert {:ok, backup1} = BackupFileServer.create_backup(file1)
      assert {:ok, backup2} = BackupFileServer.create_backup(file2)

      assert backup1 == "#{file1}.0.0.bak"
      assert backup2 == "#{file2}.0.0.bak"
      assert File.read!(backup1) == "content 1"
      assert File.read!(backup2) == "content 2"
    end

    test "fails when source file does not exist", %{project: project} do
      nonexistent_file = Path.join(project.source_root, "nonexistent.txt")

      assert {:error, :source_file_not_found} = BackupFileServer.create_backup(nonexistent_file)
    end
  end


  describe "get_session_backups/0" do
    test "positive path returns session backup files in reverse chronological order", %{project: project} do
      # Initially empty
      assert BackupFileServer.get_session_backups() == []

      # Create backups for different files
      file1 = Path.join(project.source_root, "file1.txt")
      file2 = Path.join(project.source_root, "file2.txt")
      File.write!(file1, "content 1")
      File.write!(file2, "content 2")
      
      assert {:ok, backup1} = BackupFileServer.create_backup(file1)
      assert BackupFileServer.get_session_backups() == [backup1]

      assert {:ok, backup2} = BackupFileServer.create_backup(file2)
      assert BackupFileServer.get_session_backups() == [backup2, backup1]

      # Create another backup of file1
      assert {:ok, backup3} = BackupFileServer.create_backup(file1)
      session_backups = BackupFileServer.get_session_backups()
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
      assert BackupFileServer.get_session_backups() == []

      # Create backup in current session
      assert {:ok, session_backup} = BackupFileServer.create_backup(test_file)
      
      # Should only return the current session backup, not the pre-existing one
      assert BackupFileServer.get_session_backups() == [session_backup]
      assert session_backup != existing_backup
      
      # Verify the pre-existing backup still exists but isn't tracked
      assert File.exists?(existing_backup)
      refute Enum.member?(BackupFileServer.get_session_backups(), existing_backup)
    end
  end

  describe "reset/0" do
    test "positive path clears state but respects existing backup files", %{project: project} do
      # Create some backups
      test_file = Path.join(project.source_root, "test.txt")
      File.write!(test_file, "content")
      
      BackupFileServer.create_backup(test_file)
      BackupFileServer.create_backup(test_file)
      
      assert length(BackupFileServer.get_session_backups()) == 2

      # Reset should clear state
      BackupFileServer.reset()
      assert BackupFileServer.get_session_backups() == []

      # Next backup should detect existing files and increment global counter
      # Since we already have *.0.0.bak and *.0.1.bak files, it should use global counter 1
      assert {:ok, backup} = BackupFileServer.create_backup(test_file)
      assert backup == "#{test_file}.1.0.bak"
    end

    test "clears state allowing fresh start in clean directory", %{project: project} do
      # Create backup in a new, clean file
      test_file = Path.join(project.source_root, "fresh_file.txt")
      File.write!(test_file, "content")

      # Reset server state first 
      BackupFileServer.reset()
      
      # Should start from 0.0 for a file with no existing backups
      assert {:ok, backup} = BackupFileServer.create_backup(test_file)
      assert backup == "#{test_file}.0.0.bak"
    end
  end
end
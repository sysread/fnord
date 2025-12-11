defmodule Store.Project.Entry.MigrateAbsToRelPathKeysTest do
  use Fnord.TestCase, async: false

  import LayoutMigrationHelpers

  setup do
    {:ok, project: mock_project("migrate_test")}
  end

  test "migrates legacy absolute-path metadata under files_root", %{project: project} do
    # Prepare the files_root directory
    files_root = Store.Project.files_root(project)
    File.mkdir_p!(files_root)

    # Simulate a legacy absolute-path entry file under source_root
    abs_file = Path.join(project.source_root, "legacy.txt")
    File.write!(abs_file, "content")

    # Create a legacy directory named by old hex ID
    legacy_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    legacy_dir = Path.join(files_root, legacy_id)
    File.mkdir_p!(legacy_dir)

    # Write legacy metadata.json with absolute file path
    meta = %{
      "file" => abs_file,
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
      "hash" => "dummy"
    }

    File.write!(Path.join(legacy_dir, "metadata.json"), Jason.encode!(meta))

    # Perform migration
    assert :ok = Store.Project.Entry.MigrateAbsToRelPathKeys.ensure_relative_entry_ids(project)

    # Validate that the old directory is removed and a new one exists under files_root
    entries = File.ls!(files_root)
    assert length(entries) == 1
    [new_id] = entries
    new_dir = Path.join(files_root, new_id)
    assert File.dir?(new_dir)

    # Check that metadata.json was updated to use relative path
    content = File.read!(Path.join(new_dir, "metadata.json"))
    {:ok, updated} = Jason.decode(content)
    assert updated["file"] == "legacy.txt"
  end

  test "lockfile is removed in files_root after migration", %{project: project} do
    files_root = Store.Project.files_root(project)
    lockfile = Path.join(files_root, ".migration_in_progress")
    File.rm_rf!(lockfile)
    refute File.exists?(lockfile)
    # Prepare the directory and legacy entry
    File.mkdir_p!(files_root)
    abs_file = Path.join(project.source_root, "legacy2.txt")
    File.write!(abs_file, "content")
    legacy_id = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    legacy_dir = Path.join(files_root, legacy_id)
    File.mkdir_p!(legacy_dir)

    meta = %{
      "file" => abs_file,
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
      "hash" => "dummy"
    }

    File.write!(Path.join(legacy_dir, "metadata.json"), Jason.encode!(meta))
    # Start migration asynchronously
    pid =
      spawn(fn ->
        Store.Project.Entry.MigrateAbsToRelPathKeys.ensure_relative_entry_ids(project)
      end)

    # Wait for migration to finish
    Process.monitor(pid)
    assert_receive {:DOWN, _, :process, ^pid, _}
    refute File.exists?(lockfile)
  end

  describe "idempotency of ensure_relative_entry_ids" do
    test "idempotent after initial migration", %{project: project} do
      files_root = Store.Project.files_root(project)
      File.mkdir_p!(files_root)

      # Set up a legacy directory
      abs_file = Path.join(project.source_root, "f.txt")
      File.write!(abs_file, "content")
      legacy_id = "deadbeef"
      legacy_dir = Path.join(files_root, legacy_id)
      File.mkdir_p!(legacy_dir)

      meta = %{
        "file" => abs_file,
        "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
        "hash" => "dummy"
      }

      File.write!(Path.join(legacy_dir, "metadata.json"), Jason.encode!(meta))

      # Snapshot before migration
      snapshot1 = Path.wildcard(Path.join(files_root, "*")) |> Enum.sort()

      # First migration
      assert :ok = Store.Project.Entry.MigrateAbsToRelPathKeys.ensure_relative_entry_ids(project)
      snapshot2 = Path.wildcard(Path.join(files_root, "*")) |> Enum.sort()
      refute snapshot1 == snapshot2

      # Second migration (idempotent)
      assert :ok = Store.Project.Entry.MigrateAbsToRelPathKeys.ensure_relative_entry_ids(project)
      snapshot3 = Path.wildcard(Path.join(files_root, "*")) |> Enum.sort()
      assert snapshot2 == snapshot3
    end
  end

  describe "stale lock cleanup in ensure_relative_entry_ids" do
    test "removes stale lock and migrates legacy entry", %{project: project} do
      # Prepare files_root and stale lock
      files_root = Store.Project.files_root(project)
      File.mkdir_p!(files_root)
      lockfile = Path.join(files_root, ".migration_in_progress")
      File.write!(lockfile, "invalid_pid")
      assert File.exists?(lockfile)

      # Create a legacy entry under project root
      {basename, rel_file} = create_legacy_entry(project)
      # Move legacy entry into files_root layout
      assert :ok = Store.Project.FilesDirMigration.ensure_files_dir_layout(project)
      # Stale lock should still exist
      assert File.exists?(lockfile)

      # Perform key migration, which should remove the stale lock and migrate
      assert :ok = Store.Project.Entry.MigrateAbsToRelPathKeys.ensure_relative_entry_ids(project)
      refute File.exists?(lockfile)

      # Assert the entry now lives under files_root with correct metadata
      assert_migrated(project, basename, rel_file)
    end
  end
end

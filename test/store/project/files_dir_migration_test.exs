defmodule Store.Project.FilesDirMigrationTest do
  use Fnord.TestCase, async: false

  describe "ensure_files_dir_layout/1" do
    setup do
      root = Briefly.create!(directory: true)
      project = %Store.Project{name: "p", store_path: root, source_root: nil}
      %{project: project, root: root, files_root: Store.Project.files_root(project)}
    end

    test "moves a single legacy entry into files/", %{
      project: project,
      root: root,
      files_root: files_root
    } do
      entry_id = "123"
      legacy_dir = Path.join(root, entry_id)
      File.mkdir_p!(legacy_dir)
      File.write!(Path.join(legacy_dir, "metadata.json"), "{}")

      assert :ok = Store.Project.FilesDirMigration.ensure_files_dir_layout(project)

      # Legacy dir moved
      refute File.dir?(legacy_dir)
      target = Path.join(files_root, entry_id)
      assert File.dir?(target)
      assert File.exists?(Path.join(target, "metadata.json"))
    end

    test "merges missing files when target exists", %{
      project: project,
      root: root,
      files_root: files_root
    } do
      entry_id = "456"
      legacy_dir = Path.join(root, entry_id)
      File.mkdir_p!(legacy_dir)
      # legacy provides outline and embeddings
      File.write!(Path.join(legacy_dir, "outline"), "legacy_outline")
      File.write!(Path.join(legacy_dir, "embeddings.json"), "legacy_embeddings")
      File.write!(Path.join(legacy_dir, "metadata.json"), "{\"a\":1}")
      File.write!(Path.join(legacy_dir, "summary"), "legacy_summary")

      target_dir = Path.join(files_root, entry_id)
      File.mkdir_p!(target_dir)
      # target has metadata and summary, missing others
      File.write!(Path.join(target_dir, "metadata.json"), "{\"b\":2}")
      File.write!(Path.join(target_dir, "summary"), "orig_summary")

      assert :ok = Store.Project.FilesDirMigration.ensure_files_dir_layout(project)

      # Legacy dir removed
      refute File.dir?(legacy_dir)
      # Target dir exists
      assert File.dir?(target_dir)
      # Existing files preserved
      assert File.read!(Path.join(target_dir, "metadata.json")) == "{\"b\":2}"
      assert File.read!(Path.join(target_dir, "summary")) == "orig_summary"
      # Missing files merged
      assert File.read!(Path.join(target_dir, "outline")) == "legacy_outline"
      assert File.read!(Path.join(target_dir, "embeddings.json")) == "legacy_embeddings"
    end

    test "no-op when nothing to migrate", %{project: project, root: root, files_root: files_root} do
      entry_id = "789"
      target_dir = Path.join(files_root, entry_id)
      File.mkdir_p!(target_dir)
      File.write!(Path.join(target_dir, "metadata.json"), "{}")

      assert :ok = Store.Project.FilesDirMigration.ensure_files_dir_layout(project)

      # Root legacy dir should not exist
      refute File.dir?(Path.join(root, entry_id))
      # Existing target remains
      assert File.dir?(target_dir)
    end

    test "ignores files and conversations dirs", %{project: project, root: root} do
      # Create special dirs at root
      files_dir = Path.join(root, "files")
      conv_dir = Path.join(root, "conversations")
      File.mkdir_p!(files_dir)
      File.mkdir_p!(conv_dir)
      # Place a metadata in conversations to simulate noise
      File.write!(Path.join(conv_dir, "metadata.json"), "{}")

      # Should not error or move these
      assert :ok = Store.Project.FilesDirMigration.ensure_files_dir_layout(project)

      # Directories remain
      assert File.dir?(files_dir)
      assert File.dir?(conv_dir)
    end
  end

  describe "migrate/2" do
    setup do
      root = Briefly.create!(directory: true)
      project = %Store.Project{name: "p", store_path: root, source_root: nil}
      %{project: project, root: root, files_root: Store.Project.files_root(project)}
    end

    test "moves a single legacy entry into files/", %{
      project: project,
      root: root,
      files_root: files_root
    } do
      entry_id = "123"
      legacy_dir = Path.join(root, entry_id)
      File.mkdir_p!(legacy_dir)
      File.write!(Path.join(legacy_dir, "metadata.json"), "{}")

      assert :ok =
               Store.Project.FilesDirMigration.migrate(
                 project.store_path,
                 Store.Project.files_root(project)
               )

      # Legacy dir moved
      refute File.dir?(legacy_dir)
      target = Path.join(files_root, entry_id)
      assert File.dir?(target)
      assert File.exists?(Path.join(target, "metadata.json"))
    end

    test "merges missing files when target exists", %{
      project: project,
      root: root,
      files_root: files_root
    } do
      entry_id = "456"
      legacy_dir = Path.join(root, entry_id)
      File.mkdir_p!(legacy_dir)
      # legacy provides outline and embeddings
      File.write!(Path.join(legacy_dir, "outline"), "legacy_outline")
      File.write!(Path.join(legacy_dir, "embeddings.json"), "legacy_embeddings")
      File.write!(Path.join(legacy_dir, "metadata.json"), "{\"a\":1}")
      File.write!(Path.join(legacy_dir, "summary"), "legacy_summary")

      target_dir = Path.join(files_root, entry_id)
      File.mkdir_p!(target_dir)
      # target has metadata and summary, missing others
      File.write!(Path.join(target_dir, "metadata.json"), "{\"b\":2}")
      File.write!(Path.join(target_dir, "summary"), "orig_summary")

      assert :ok =
               Store.Project.FilesDirMigration.migrate(
                 project.store_path,
                 Store.Project.files_root(project)
               )

      # Legacy dir removed
      refute File.dir?(legacy_dir)
      # Target dir exists
      assert File.dir?(target_dir)
      # Existing files preserved
      assert File.read!(Path.join(target_dir, "metadata.json")) == "{\"b\":2}"
      assert File.read!(Path.join(target_dir, "summary")) == "orig_summary"
      # Missing files merged
      assert File.read!(Path.join(target_dir, "outline")) == "legacy_outline"
      assert File.read!(Path.join(target_dir, "embeddings.json")) == "legacy_embeddings"
    end

    test "no-op when nothing to migrate", %{project: project, root: root, files_root: files_root} do
      entry_id = "789"
      target_dir = Path.join(files_root, entry_id)
      File.mkdir_p!(target_dir)
      File.write!(Path.join(target_dir, "metadata.json"), "{}")

      assert :ok =
               Store.Project.FilesDirMigration.migrate(
                 project.store_path,
                 Store.Project.files_root(project)
               )

      # Root legacy dir should not exist
      refute File.dir?(Path.join(root, entry_id))
      # Existing target remains
      assert File.dir?(target_dir)
    end

    test "ignores files and conversations dirs", %{project: project, root: root} do
      # Create special dirs at root
      files_dir = Path.join(root, "files")
      conv_dir = Path.join(root, "conversations")
      File.mkdir_p!(files_dir)
      File.mkdir_p!(conv_dir)
      # Place a metadata in conversations to simulate noise
      File.write!(Path.join(conv_dir, "metadata.json"), "{}")

      # Should not error or move these
      assert :ok =
               Store.Project.FilesDirMigration.migrate(
                 project.store_path,
                 Store.Project.files_root(project)
               )

      # Directories remain
      assert File.dir?(files_dir)
      assert File.dir?(conv_dir)
    end
  end
end

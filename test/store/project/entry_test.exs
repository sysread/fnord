defmodule Store.Project.EntryTest do
  use Fnord.TestCase

  @text "how now brown bureaucrat"
  @alt_text "now is the time for all good men to come to the aid of their country"

  setup do: {:ok, project: mock_project("blarg")}

  describe "new_from_file_path/2" do
    test "basics", ctx do
      entry = Store.Project.Entry.new_from_file_path(ctx.project, "a.txt")

      assert entry.project == ctx.project
      assert entry.file == Path.join(ctx.project.source_root, "a.txt")
      assert entry.rel_path == "a.txt"
      assert String.starts_with?(entry.store_path, ctx.project.store_path)
      assert String.ends_with?(entry.store_path, entry.key)

      refute is_nil(entry.metadata)
      refute is_nil(entry.summary)
      refute is_nil(entry.outline)
      refute is_nil(entry.embeddings)
    end
  end

  describe "exists_in_store?/1" do
    test "false before indexing", ctx do
      file = "a.txt"
      path = mock_source_file(ctx.project, file, @text)
      entry = Store.Project.Entry.new_from_file_path(ctx.project, path)

      refute Store.Project.Entry.exists_in_store?(entry)
    end

    test "true after indexing", ctx do
      file = "a.txt"
      path = mock_source_file(ctx.project, file, @text)
      entry = Store.Project.Entry.new_from_file_path(ctx.project, path)

      # Create an indexer for the project
      idx =
        Cmd.Index.new(%{
          project: ctx.project.name,
          directory: ctx.project.source_root,
          quiet: true
        })

      # Run the indexing process
      Cmd.Index.perform_task(idx)

      assert Store.Project.Entry.exists_in_store?(entry)
    end
  end

  describe "create/1 and delete/1" do
    test "basics", ctx do
      entry = Store.Project.Entry.new_from_file_path(ctx.project, "a.txt")
      refute Store.Project.Entry.exists_in_store?(entry)

      Store.Project.Entry.create(entry)
      assert Store.Project.Entry.exists_in_store?(entry)

      Store.Project.Entry.delete(entry)
      refute Store.Project.Entry.exists_in_store?(entry)
    end
  end

  describe "is_incomplete/1" do
    test "positive path", ctx do
      path = mock_source_file(ctx.project, "a.txt", @text)
      entry = Store.Project.Entry.new_from_file_path(ctx.project, path)
      Store.Project.Entry.create(entry)

      Store.Project.Entry.Metadata.write(entry.metadata, %{})
      Store.Project.Entry.Summary.write(entry.summary, "summary text")
      Store.Project.Entry.Outline.write(entry.outline, "- outline\n  - sub-outline")
      Store.Project.Entry.Embeddings.write(entry.embeddings, [[1, 2, 3]])

      refute Store.Project.Entry.is_incomplete?(entry)
    end

    test "true when missing metadata", ctx do
      path = mock_source_file(ctx.project, "a.txt", @text)
      entry = Store.Project.Entry.new_from_file_path(ctx.project, path)
      Store.Project.Entry.create(entry)

      Store.Project.Entry.Summary.write(entry.summary, "summary text")
      Store.Project.Entry.Outline.write(entry.outline, "- outline\n  - sub-outline")
      Store.Project.Entry.Embeddings.write(entry.embeddings, [[1, 2, 3]])

      assert Store.Project.Entry.is_incomplete?(entry)
    end

    test "true when missing summary", ctx do
      path = mock_source_file(ctx.project, "a.txt", @text)
      entry = Store.Project.Entry.new_from_file_path(ctx.project, path)
      Store.Project.Entry.create(entry)

      Store.Project.Entry.Metadata.write(entry.metadata, %{})
      Store.Project.Entry.Outline.write(entry.outline, "- outline\n  - sub-outline")
      Store.Project.Entry.Embeddings.write(entry.embeddings, [[1, 2, 3]])

      assert Store.Project.Entry.is_incomplete?(entry)
    end

    test "true when missing outline", ctx do
      path = mock_source_file(ctx.project, "a.txt", @text)
      entry = Store.Project.Entry.new_from_file_path(ctx.project, path)
      Store.Project.Entry.create(entry)

      Store.Project.Entry.Metadata.write(entry.metadata, %{})
      Store.Project.Entry.Summary.write(entry.summary, "summary text")
      Store.Project.Entry.Embeddings.write(entry.embeddings, [[1, 2, 3]])

      assert Store.Project.Entry.is_incomplete?(entry)
    end

    test "true when missing embeddings", ctx do
      path = mock_source_file(ctx.project, "a.txt", @text)
      entry = Store.Project.Entry.new_from_file_path(ctx.project, path)
      Store.Project.Entry.create(entry)

      Store.Project.Entry.Metadata.write(entry.metadata, %{})
      Store.Project.Entry.Summary.write(entry.summary, "summary text")
      Store.Project.Entry.Outline.write(entry.outline, "- outline\n  - sub-outline")

      assert Store.Project.Entry.is_incomplete?(entry)
    end
  end

  describe "hash_is_current?/1" do
    test "true when file has not changed", ctx do
      path = mock_source_file(ctx.project, "a.txt", @text)
      entry = Store.Project.Entry.new_from_file_path(ctx.project, path)

      Store.Project.Entry.create(entry)
      Store.Project.Entry.Metadata.write(entry.metadata, %{})

      assert Store.Project.Entry.hash_is_current?(entry)
    end

    test "false when file has changed", ctx do
      path = mock_source_file(ctx.project, "a.txt", @text)
      entry = Store.Project.Entry.new_from_file_path(ctx.project, path)

      Store.Project.Entry.create(entry)
      Store.Project.Entry.Metadata.write(entry.metadata, %{})

      # Update the source file
      File.write(entry.file, @alt_text)

      refute Store.Project.Entry.hash_is_current?(entry)
    end
  end

  describe "is_stale?/1" do
    test "positive path", ctx do
      path = mock_source_file(ctx.project, "a.txt", @text)
      entry = Store.Project.Entry.new_from_file_path(ctx.project, path)
      Store.Project.Entry.create(entry)

      Store.Project.Entry.Metadata.write(entry.metadata, %{})
      Store.Project.Entry.Summary.write(entry.summary, "summary text")
      Store.Project.Entry.Outline.write(entry.outline, "- outline\n  - sub-outline")
      Store.Project.Entry.Embeddings.write(entry.embeddings, [[1, 2, 3]])

      refute Store.Project.Entry.is_stale?(entry)
    end

    test "true when not exists_in_store?", ctx do
      path = mock_source_file(ctx.project, "a.txt", @text)
      entry = Store.Project.Entry.new_from_file_path(ctx.project, path)

      assert Store.Project.Entry.is_stale?(entry)
    end

    test "true when is_incomplete?", ctx do
      path = mock_source_file(ctx.project, "a.txt", @text)
      entry = Store.Project.Entry.new_from_file_path(ctx.project, path)
      Store.Project.Entry.create(entry)

      Store.Project.Entry.Metadata.write(entry.metadata, %{})
      Store.Project.Entry.Summary.write(entry.summary, "summary text")
      Store.Project.Entry.Outline.write(entry.outline, "- outline\n  - sub-outline")
      # Missing entry.embeddings

      assert Store.Project.Entry.is_stale?(entry)
    end

    test "true when not hash_is_current?", ctx do
      path = mock_source_file(ctx.project, "a.txt", @text)
      entry = Store.Project.Entry.new_from_file_path(ctx.project, path)
      Store.Project.Entry.create(entry)

      Store.Project.Entry.Metadata.write(entry.metadata, %{})
      Store.Project.Entry.Summary.write(entry.summary, "summary text")
      Store.Project.Entry.Outline.write(entry.outline, "- outline\n  - sub-outline")
      Store.Project.Entry.Embeddings.write(entry.embeddings, [[1, 2, 3]])

      # Update the source file
      File.write!(entry.file, @alt_text)

      refute Store.Project.Entry.hash_is_current?(entry)
      assert Store.Project.Entry.is_stale?(entry)
    end
  end

  describe "read_source_file?/1" do
    test "basics", ctx do
      path = mock_source_file(ctx.project, "a.txt", @text)
      entry = Store.Project.Entry.new_from_file_path(ctx.project, path)
      assert {:ok, @text} = Store.Project.Entry.read_source_file(entry)
    end
  end

  describe "save/4 <=> read/1" do
    test "basics", ctx do
      path = mock_source_file(ctx.project, "a.txt", @text)
      entry = Store.Project.Entry.new_from_file_path(ctx.project, path)
      Store.Project.Entry.create(entry)

      Store.Project.Entry.save(
        entry,
        "summary text",
        "- outline\n  - sub-outline",
        [1, 2, 3]
      )

      file = entry.file

      assert {:ok,
              %{
                "file" => ^file,
                "summary" => "summary text",
                "outline" => "- outline\n  - sub-outline",
                "embeddings" => [1, 2, 3],
                "timestamp" => _,
                "hash" => _
              }} = Store.Project.Entry.read(entry)
    end

    test "metadata stores relative path but read returns absolute", ctx do
      # Create subdirectory first
      subdir = Path.join(ctx.project.source_root, "subdir")
      File.mkdir_p!(subdir)

      path = mock_source_file(ctx.project, "subdir/b.txt", @text)
      entry = Store.Project.Entry.new_from_file_path(ctx.project, path)
      Store.Project.Entry.create(entry)

      Store.Project.Entry.save(
        entry,
        "summary text",
        "outline",
        [1, 2, 3]
      )

      # Read the raw metadata file to verify it stores relative path
      metadata_path = Store.Project.Entry.metadata_file_path(entry)
      {:ok, raw_metadata} = File.read(metadata_path)
      {:ok, metadata} = Jason.decode(raw_metadata)

      # relative path stored
      assert metadata["file"] == "subdir/b.txt"

      # But the read/1 function should return absolute path for API compatibility
      {:ok, entry_data} = Store.Project.Entry.read(entry)
      # absolute path returned
      assert entry_data["file"] == entry.file
    end
  end

  describe "id_for_rel_path/1" do
    test "generates reversible IDs for short paths" do
      rel_path = "src/main.ex"
      id = Store.Project.Entry.id_for_rel_path(rel_path)

      assert String.starts_with?(id, "r1-")
      # Base64url encode "src/main.ex" -> "c3JjL21haW4uZXg"
      assert id == "r1-c3JjL21haW4uZXg"
    end

    test "generates hash IDs for very long paths" do
      # Create a path that would exceed the 200 character limit when base64 encoded
      long_path = String.duplicate("very_long_directory_name/", 20) <> "file.txt"
      id = Store.Project.Entry.id_for_rel_path(long_path)

      assert String.starts_with?(id, "h1-")
      # "h1-" + 64 char SHA256 hash
      assert String.length(id) == 3 + 64
    end

    test "handles special characters in paths" do
      rel_path = "test files/special chars & symbols.txt"
      id = Store.Project.Entry.id_for_rel_path(rel_path)

      assert String.starts_with?(id, "r1-")
      # Should be URL-safe (no +, /, or padding)
      refute String.contains?(id, "+")
      refute String.contains?(id, "/")
      refute String.ends_with?(id, "=")
    end

    test "roundtrip: id_for_rel_path/1 and rel_path_from_id/1" do
      rel_paths = [
        "src/main.ex",
        "test/support/helpers.ex",
        "docs/README.md",
        "files with spaces/and & symbols.txt"
      ]

      for rel_path <- rel_paths do
        id = Store.Project.Entry.id_for_rel_path(rel_path)

        if String.starts_with?(id, "r1-") do
          # Should be reversible
          assert {:ok, ^rel_path} = Store.Project.Entry.rel_path_from_id(id)
        else
          # Hash-based IDs are not reversible
          assert {:error, :not_reversible} = Store.Project.Entry.rel_path_from_id(id)
        end
      end
    end

    test "rel_path_from_id/1 with legacy and hash IDs" do
      # Legacy absolute path hash (64-char hex)
      legacy_id = "a123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      assert {:error, :not_reversible} = Store.Project.Entry.rel_path_from_id(legacy_id)

      # Hash-based ID (h1- prefix)
      hash_id = "h1-a123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      assert {:error, :not_reversible} = Store.Project.Entry.rel_path_from_id(hash_id)

      # Invalid reversible ID
      invalid_id = "r1-invalid_base64!!!"
      assert {:error, :not_reversible} = Store.Project.Entry.rel_path_from_id(invalid_id)
    end
  end

  describe "new ID scheme integration" do
    test "new entries use relative-path based IDs", ctx do
      # Create src directory first
      src_dir = Path.join(ctx.project.source_root, "src")
      File.mkdir_p!(src_dir)

      path = mock_source_file(ctx.project, "src/new_file.ex", @text)
      entry = Store.Project.Entry.new_from_file_path(ctx.project, path)

      # Key should use the new scheme
      assert String.starts_with?(entry.key, "r1-")

      # Rel path should be correct
      assert entry.rel_path == "src/new_file.ex"

      # Store path should use the new key
      assert String.ends_with?(entry.store_path, entry.key)
    end

    test "can read legacy entries with absolute paths in metadata", ctx do
      # This test simulates reading an entry that was created before the migration
      path = mock_source_file(ctx.project, "legacy.txt", @text)
      entry = Store.Project.Entry.new_from_file_path(ctx.project, path)
      Store.Project.Entry.create(entry)

      # Manually create legacy metadata with absolute path
      metadata_path = Store.Project.Entry.metadata_file_path(entry)

      legacy_metadata = %{
        # absolute path (legacy format)
        "file" => entry.file,
        "timestamp" => DateTime.utc_now(),
        "hash" => "dummy_hash"
      }

      {:ok, json} = Jason.encode(legacy_metadata)
      File.write!(metadata_path, json)

      # Should be able to read and create entry from the legacy metadata
      legacy_entry = Store.Project.Entry.new_from_entry_path(ctx.project, entry.store_path)
      assert legacy_entry.file == entry.file
      assert legacy_entry.rel_path == "legacy.txt"
    end

    test "migration is reentrant - same process can call it multiple times", ctx do
      # Create a test file
      path = mock_source_file(ctx.project, "reentrant_test.txt", @text)
      entry = Store.Project.Entry.new_from_file_path(ctx.project, path)
      Store.Project.Entry.create(entry)

      # Manually create legacy metadata with absolute path to force migration
      metadata_path = Store.Project.Entry.metadata_file_path(entry)

      legacy_metadata = %{
        # absolute path (legacy format)
        "file" => entry.file,
        "timestamp" => DateTime.utc_now(),
        "hash" => "dummy_hash"
      }

      {:ok, json} = Jason.encode(legacy_metadata)
      File.write!(metadata_path, json)

      # First migration call should succeed
      assert :ok ==
               Store.Project.Entry.MigrateAbsToRelPathKeys.ensure_relative_entry_ids(ctx.project)

      # Second migration call from same process should be reentrant (not deadlock)
      assert :ok ==
               Store.Project.Entry.MigrateAbsToRelPathKeys.ensure_relative_entry_ids(ctx.project)

      # Verify the entry is properly migrated
      migrated_entry = Store.Project.Entry.new_from_entry_path(ctx.project, entry.store_path)
      assert migrated_entry.file == entry.file
      assert migrated_entry.rel_path == "reentrant_test.txt"
    end
  end
end

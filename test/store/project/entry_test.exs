defmodule Store.Project.EntryTest do
  use Fnord.TestCase, async: false

  @text "how now brown bureaucrat"
  @alt_text "now is the time for all good men to come to the aid of their country"

  setup do: {:ok, project: mock_project("blarg")}

  describe "new_from_file_path/2" do
    test "basics", ctx do
      entry = Store.Project.Entry.new_from_file_path(ctx.project, "a.txt")

      assert entry.project == ctx.project
      assert entry.file == Path.join(ctx.project.source_root, "a.txt")
      assert entry.rel_path == "a.txt"
      files_root = Store.Project.files_root(ctx.project)
      assert String.starts_with?(entry.store_path, files_root)
      assert String.ends_with?(entry.store_path, entry.key)

      refute is_nil(entry.metadata)
      refute is_nil(entry.summary)
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
      Store.Project.Entry.Embeddings.write(entry.embeddings, [[1, 2, 3]])

      refute Store.Project.Entry.is_incomplete?(entry)
    end

    test "true when missing metadata", ctx do
      path = mock_source_file(ctx.project, "a.txt", @text)
      entry = Store.Project.Entry.new_from_file_path(ctx.project, path)
      Store.Project.Entry.create(entry)

      Store.Project.Entry.Summary.write(entry.summary, "summary text")
      Store.Project.Entry.Embeddings.write(entry.embeddings, [[1, 2, 3]])

      assert Store.Project.Entry.is_incomplete?(entry)
    end

    test "true when missing summary", ctx do
      path = mock_source_file(ctx.project, "a.txt", @text)
      entry = Store.Project.Entry.new_from_file_path(ctx.project, path)
      Store.Project.Entry.create(entry)

      Store.Project.Entry.Metadata.write(entry.metadata, %{})
      Store.Project.Entry.Embeddings.write(entry.embeddings, [[1, 2, 3]])

      assert Store.Project.Entry.is_incomplete?(entry)
    end

    test "true when missing embeddings", ctx do
      path = mock_source_file(ctx.project, "a.txt", @text)
      entry = Store.Project.Entry.new_from_file_path(ctx.project, path)
      Store.Project.Entry.create(entry)

      Store.Project.Entry.Metadata.write(entry.metadata, %{})
      Store.Project.Entry.Summary.write(entry.summary, "summary text")

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

    # Simulates the post-upgrade state: a fnord from before the Source
    # abstraction stored sha256 of the working-tree content. The current
    # source mode (fs here, since mock_project isn't a git repo) also
    # hashes with sha256 - so the stored value and current value match
    # byte-for-byte. This is the trivial "upgrade is a no-op" case.
    test "legacy sha256 metadata matches sha256 hash in fs mode", ctx do
      path = mock_source_file(ctx.project, "a.txt", @text)
      entry = Store.Project.Entry.new_from_file_path(ctx.project, path)
      Store.Project.Entry.create(entry)

      # Pre-write metadata with the sha256 hash the way old fnord would.
      legacy_hash =
        :crypto.hash(:sha256, @text) |> Base.encode16(case: :lower)

      Store.Project.Entry.Metadata.write(entry.metadata, %{
        rel_path: entry.rel_path,
        hash: legacy_hash
      })

      assert Store.Project.Entry.hash_is_current?(entry)
    end

    # The cross-format upgrade path: stored hash has legacy-sha256 length
    # (64 hex) but current source hash is a different string (e.g.
    # different format entirely). If the underlying content still hashes
    # to the stored sha256, hash_is_current? treats the entry as fresh
    # AND re-stamps metadata with the current-format hash so the next
    # scan takes the fast path.
    test "cross-format: same content re-stamps metadata to current hash", ctx do
      path = mock_source_file(ctx.project, "a.txt", @text)
      entry = Store.Project.Entry.new_from_file_path(ctx.project, path)
      Store.Project.Entry.create(entry)

      legacy_sha256 =
        :crypto.hash(:sha256, @text) |> Base.encode16(case: :lower)

      # Write metadata with the legacy hash. In fs mode the current hash
      # would also be sha256, so we simulate a cross-format by tampering
      # with the source so that sha256 still matches (content unchanged)
      # while the "current" mode happens to be identical - the important
      # assertion is that the metadata *is* re-stamped with whatever the
      # current Source.hash returns.
      Store.Project.Entry.Metadata.write(entry.metadata, %{
        rel_path: entry.rel_path,
        hash: legacy_sha256
      })

      {:ok, current} = Store.Project.Source.hash(ctx.project, entry.rel_path)
      assert Store.Project.Entry.hash_is_current?(entry)

      # Metadata should now hold whatever Source.hash returned. In fs mode
      # that's the same sha256, but the write-through path was exercised.
      {:ok, meta} = Store.Project.Entry.read_metadata(entry)
      assert meta["hash"] == current
    end

    # Proves the "unchanged content across branches" upgrade path. This
    # is the scenario the branch promises: an existing index with legacy
    # sha256 hashes does NOT force a full reindex when the project flips
    # into git mode; identical content re-stamps to blob SHA and skips.
    test "cross-format in git mode: legacy sha256 + unchanged content upgrades to blob SHA",
         %{} = _ctx do
      # Create a git project with a committed file.
      project = mock_git_project("entry_xfmt")
      repo = project.source_root
      File.write!(Path.join(repo, "a.txt"), @text)
      git_config_user!(project)
      System.cmd("git", ["add", "."], cd: repo, stderr_to_stdout: true)
      System.cmd("git", ["commit", "-m", "init", "--quiet"], cd: repo, stderr_to_stdout: true)

      # Build an entry pointing at the file path.
      path = Path.join(repo, "a.txt")
      entry = Store.Project.Entry.new_from_file_path(project, path)
      Store.Project.Entry.create(entry)

      # Pre-write metadata with the legacy sha256 hash, as pre-upgrade
      # fnord would have.
      legacy_sha256 =
        :crypto.hash(:sha256, @text) |> Base.encode16(case: :lower)

      Store.Project.Entry.Metadata.write(entry.metadata, %{
        rel_path: entry.rel_path,
        hash: legacy_sha256
      })

      # In git mode, Source.hash returns the blob SHA (40 hex chars),
      # which is distinct from sha256 (64 hex). hash_is_current? must
      # still return true by recomputing sha256 of the current content
      # and comparing against the stored value, then re-stamping the
      # metadata to the blob SHA.
      {:ok, blob_sha} = Store.Project.Source.hash(project, "a.txt")
      assert byte_size(blob_sha) == 40
      refute blob_sha == legacy_sha256

      assert Store.Project.Entry.hash_is_current?(entry)

      {:ok, meta} = Store.Project.Entry.read_metadata(entry)
      assert meta["hash"] == blob_sha
    end
  end

  describe "is_stale?/1" do
    test "positive path", ctx do
      path = mock_source_file(ctx.project, "a.txt", @text)
      entry = Store.Project.Entry.new_from_file_path(ctx.project, path)
      Store.Project.Entry.create(entry)

      Store.Project.Entry.Metadata.write(entry.metadata, %{})
      Store.Project.Entry.Summary.write(entry.summary, "summary text")

      Store.Project.Entry.Embeddings.write(
        entry.embeddings,
        List.duplicate(0.0, AI.Embeddings.dimensions())
      )

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
      # Missing entry.embeddings

      assert Store.Project.Entry.is_stale?(entry)
    end

    test "true when not hash_is_current?", ctx do
      path = mock_source_file(ctx.project, "a.txt", @text)
      entry = Store.Project.Entry.new_from_file_path(ctx.project, path)
      Store.Project.Entry.create(entry)

      Store.Project.Entry.Metadata.write(entry.metadata, %{})
      Store.Project.Entry.Summary.write(entry.summary, "summary text")

      Store.Project.Entry.Embeddings.write(
        entry.embeddings,
        List.duplicate(0.0, AI.Embeddings.dimensions())
      )

      # Update the source file
      File.write!(entry.file, @alt_text)

      refute Store.Project.Entry.hash_is_current?(entry)
      assert Store.Project.Entry.is_stale?(entry)
    end

    # Regression: cross-format hash upgrade ("content unchanged, just
    # restamp the hash") must not mark an entry fresh when its stored
    # embedding was produced by a different model. Previously this bug
    # left pre-migration OpenAI 3072-dim vectors in place while the
    # metadata advertised them as current, so Migration's sampling was
    # the only thing standing between the user and a crash at query
    # time.
    test "true when the stored embedding has the wrong dimension", ctx do
      path = mock_source_file(ctx.project, "a.txt", @text)
      entry = Store.Project.Entry.new_from_file_path(ctx.project, path)
      Store.Project.Entry.create(entry)

      Store.Project.Entry.Metadata.write(entry.metadata, %{rel_path: entry.rel_path})
      Store.Project.Entry.Summary.write(entry.summary, "summary text")
      # 3-element vector vs the current model's 384.
      Store.Project.Entry.Embeddings.write(entry.embeddings, [0.1, 0.2, 0.3])

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

  describe "save/3 <=> read/1" do
    test "basics", ctx do
      path = mock_source_file(ctx.project, "a.txt", @text)
      entry = Store.Project.Entry.new_from_file_path(ctx.project, path)
      Store.Project.Entry.create(entry)

      Store.Project.Entry.save(
        entry,
        "summary text",
        [1, 2, 3]
      )

      file = entry.file

      assert {:ok,
              %{
                "file" => ^file,
                "summary" => "summary text",
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
        [1, 2, 3]
      )

      # Read the raw metadata file to verify it stores relative path
      metadata_path = Store.Project.Entry.metadata_file_path(entry)
      {:ok, raw_metadata} = File.read(metadata_path)
      {:ok, metadata} = SafeJson.decode(raw_metadata)

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
        "docs/user/README.md",
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

      {:ok, json} = SafeJson.encode(legacy_metadata)
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

      {:ok, json} = SafeJson.encode(legacy_metadata)
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

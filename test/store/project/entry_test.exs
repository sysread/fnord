defmodule Store.Project.EntryTest do
  use Fnord.TestCase

  @text "how now brown bureaucrat"
  @alt_text "now is the time for all good men to come to the aid of their country"

  setup do: set_config(workers: 1, quiet: true)
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
  end
end

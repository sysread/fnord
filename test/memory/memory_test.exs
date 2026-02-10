defmodule MemoryTest do
  use Fnord.TestCase, async: false

  describe "new/4 validation and uniqueness" do
    test "rejects invalid titles" do
      # Previously a single-space title was rejected. With relaxed validation,
      # trimming makes it empty and it should still be rejected.
      assert {:error, :invalid_title} = Memory.new(:global, " ", "content", [])
    end

    test "validate_title/1 returns errors for invalid titles" do
      assert {:error, reasons} = Memory.validate_title(" ")
      assert is_list(reasons)
      assert "must not be empty" in reasons
    end

    test "accepts titles with punctuation like colon+space" do
      assert {:ok, _} = Memory.new(:global, "Foo: bar baz", "c", [])
    end

    test "rejects duplicate titles within the same scope" do
      title = "Dup Title"
      base = Path.join(Store.store_home(), "memory")
      File.mkdir_p!(base)
      slug = Memory.title_to_slug(title)
      file = Path.join(base, "#{slug}.json")
      File.write!(file, "{}")
      assert {:error, :duplicate_title} = Memory.new(:global, title, "two", [])
    end

    test "accepts same title in different scopes" do
      assert {:ok, _} = Memory.new(:global, "Scoped Title", "g", [])
      assert {:ok, _} = Memory.new(:project, "Scoped Title", "p", [])
    end
  end

  describe "marshal/unmarshal" do
    test "round trips a memory struct" do
      ts1 = DateTime.utc_now() |> DateTime.to_iso8601()
      ts2 = DateTime.utc_now() |> DateTime.to_iso8601()

      mem = %Memory{
        scope: :global,
        title: "Round Trip",
        slug: Memory.title_to_slug("Round Trip"),
        content: "hello",
        topics: ["t"],
        embeddings: [0.1, 0.2],
        inserted_at: ts1,
        updated_at: ts2
      }

      assert {:ok, json} = Memory.marshal(mem)
      assert {:ok, decoded} = Memory.unmarshal(json)

      assert decoded.scope == mem.scope
      assert decoded.title == mem.title
      assert decoded.slug == mem.slug
      assert decoded.content == mem.content
      assert decoded.topics == mem.topics
      assert decoded.embeddings == mem.embeddings
      assert decoded.inserted_at == mem.inserted_at
      assert decoded.updated_at == mem.updated_at
    end

    test "unmarshal tolerates legacy json missing timestamps" do
      legacy =
        %{
          "scope" => "global",
          "title" => "Legacy",
          "slug" => "legacy",
          "content" => "hello",
          "topics" => [],
          "embeddings" => [0.1]
        }
        |> Jason.encode!()

      assert {:ok, decoded} = Memory.unmarshal(legacy)
      assert decoded.inserted_at == nil
      assert decoded.updated_at == nil
    end
  end

  describe "save/1 timestamp migration" do
    test "save fills missing timestamps" do
      base = Path.join(Store.store_home(), "memory")
      File.mkdir_p!(base)

      mem = %Memory{
        scope: :global,
        title: "Fill Missing",
        slug: "fill-missing",
        content: "hello",
        topics: [],
        # Ensure save does not try to call the embeddings API.
        embeddings: [0.1],
        inserted_at: nil,
        updated_at: nil
      }

      # Save using skip_embeddings to avoid network/API calls in tests
      assert {:ok, saved} = Memory.save(mem, skip_embeddings: true)
      assert is_binary(saved.inserted_at)
      assert saved.inserted_at != ""
      assert is_binary(saved.updated_at)
      assert saved.updated_at != ""
    end

    test "read auto-saves when timestamps missing" do
      title = "Legacy Read"
      slug = Memory.title_to_slug(title)

      base = Path.join(Store.store_home(), "memory")
      File.mkdir_p!(base)

      file = Path.join(base, "#{slug}.json")

      legacy =
        %{
          "scope" => "global",
          "title" => title,
          "slug" => slug,
          "content" => "hello",
          "topics" => [],
          # Ensure the auto-save path does not try to call the embeddings API.
          "embeddings" => [0.1]
        }
        |> Jason.encode!()

      File.write!(file, legacy)

      assert {:ok, migrated} = Memory.read(:global, title)
      assert is_binary(migrated.inserted_at)
      assert migrated.inserted_at != ""
      assert is_binary(migrated.updated_at)
      assert migrated.updated_at != ""

      on_disk = file |> File.read!() |> Jason.decode!()
      assert Map.has_key?(on_disk, "inserted_at")
      assert Map.has_key?(on_disk, "updated_at")
      assert is_binary(on_disk["inserted_at"])
      assert on_disk["inserted_at"] != ""
      assert is_binary(on_disk["updated_at"])
      assert on_disk["updated_at"] != ""
    end
  end

  describe "is_stale?/1 and append/2" do
    test "slug collision: distinct titles that slugify the same can both be saved" do
      title1 = "Foo Bar"
      # extra space -> same slug
      title2 = "Foo  Bar"

      base = Path.join(Store.store_home(), "memory")
      File.mkdir_p!(base)

      {:ok, m1} = Memory.new(:global, title1, "c1", [])
      assert {:ok, _saved1} = Memory.save(m1)

      {:ok, m2} = Memory.new(:global, title2, "c2", [])
      # Saving second should not overwrite the first; either succeed or disambiguate
      assert {:ok, _saved2} = Memory.save(m2)

      # Both titles should be readable
      assert {:ok, _} = Memory.read(:global, title1)
      assert {:ok, _} = Memory.read(:global, title2)
    end

    test "is_stale?/1 is true when embeddings are nil" do
      mem = %Memory{
        scope: :global,
        title: "S",
        slug: nil,
        content: "c",
        topics: [],
        embeddings: nil,
        inserted_at: nil,
        updated_at: nil
      }

      assert Memory.is_stale?(mem)
    end

    test "append/2 clears embeddings" do
      mem = %Memory{
        scope: :global,
        title: "A",
        slug: nil,
        content: "c",
        topics: [],
        embeddings: [0.1],
        inserted_at: nil,
        updated_at: nil
      }

      updated = Memory.append(mem, " more")
      assert updated.content == "c more"
      assert updated.embeddings == nil
      assert is_binary(updated.updated_at)
      assert updated.updated_at != ""
    end
  end

  describe "ensure_timestamps/1" do
    test "save ensures timestamps for missing and respects existing ones" do
      ts = DateTime.utc_now() |> DateTime.to_iso8601()

      base = Path.join(Store.store_home(), "memory")
      File.mkdir_p!(base)

      mem = %Memory{
        scope: :global,
        title: "Test Timestamp",
        slug: Memory.title_to_slug("Test Timestamp"),
        content: "c",
        topics: [],
        embeddings: nil,
        inserted_at: nil,
        updated_at: nil
      }

      assert {:ok, saved} = Memory.save(mem, skip_embeddings: true)
      assert is_binary(saved.inserted_at) and saved.inserted_at != ""
      assert is_binary(saved.updated_at) and saved.updated_at != ""

      mem2 = %{mem | inserted_at: ts, updated_at: ts}
      assert {:ok, saved2} = Memory.save(mem2, skip_embeddings: true)
      assert saved2.inserted_at == ts
      assert saved2.updated_at == ts
    end
  end
end

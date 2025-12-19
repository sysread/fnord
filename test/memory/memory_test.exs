defmodule MemoryTest do
  use Fnord.TestCase, async: false

  describe "new/4 validation and uniqueness" do
    test "rejects invalid titles" do
      assert {:error, :invalid_title} = Memory.new(:global, " ", "content", [])
    end

    test "validate_title/1 returns errors for invalid titles" do
      assert {:error, reasons} = Memory.validate_title(" ")
      assert is_list(reasons)
      assert "must not be empty" in reasons
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
      mem = %Memory{
        scope: :global,
        title: "Round Trip",
        slug: Memory.title_to_slug("Round Trip"),
        content: "hello",
        topics: ["t"],
        embeddings: [0.1, 0.2]
      }

      assert {:ok, json} = Memory.marshal(mem)
      assert {:ok, decoded} = Memory.unmarshal(json)

      assert decoded.scope == mem.scope
      assert decoded.title == mem.title
      assert decoded.slug == mem.slug
      assert decoded.content == mem.content
      assert decoded.topics == mem.topics
      assert decoded.embeddings == mem.embeddings
    end
  end

  describe "is_stale?/1 and append/2" do
    test "is_stale?/1 is true when embeddings are nil" do
      mem = %Memory{
        scope: :global,
        title: "S",
        slug: nil,
        content: "c",
        topics: [],
        embeddings: nil
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
        embeddings: [0.1]
      }

      updated = Memory.append(mem, " more")
      assert updated.content == "c more"
      assert updated.embeddings == nil
    end
  end
end

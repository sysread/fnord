defmodule Memory.GlobalTest do
  use Fnord.TestCase, async: false

  describe "init/0" do
    test "creates the global memory directory and drops old storage if present", %{home_dir: home} do
      old_path = Path.join([home, ".fnord", "memories"])
      new_path = Path.join([home, ".fnord", "memory"])

      File.mkdir_p!(old_path)
      assert File.exists?(old_path)

      assert :ok = Memory.Global.init()

      # old storage is removed
      refute File.exists?(old_path)

      # new storage exists
      assert File.exists?(new_path)
    end
  end

  describe "list/0, save/1, read/1, forget/1" do
    setup %{home_dir: home} do
      # ensure fresh storage dir
      base = Path.join([home, ".fnord", "memory"])
      File.rm_rf!(base)
      File.mkdir_p!(base)
      :ok
    end

    test "save/1 writes a memory that can be listed and read back" do
      mem = %Memory{
        scope: :global,
        title: "Global Test",
        slug: Memory.title_to_slug("Global Test"),
        content: "some content",
        topics: ["topic"],
        embeddings: [0.1, 0.2]
      }

      assert :ok = Memory.Global.save(mem)
      assert {:ok, titles} = Memory.Global.list()
      assert "Global Test" in titles

      assert {:ok, loaded} = Memory.Global.read("Global Test")
      assert loaded.title == mem.title
      assert loaded.content == mem.content
    end

    test "forget/1 removes a stored memory" do
      mem = %Memory{
        scope: :global,
        title: "To Forget",
        slug: Memory.title_to_slug("To Forget"),
        content: "content",
        topics: [],
        embeddings: [0.0]
      }

      assert :ok = Memory.Global.save(mem)
      assert {:ok, titles} = Memory.Global.list()
      assert "To Forget" in titles

      assert :ok = Memory.Global.forget("To Forget")
      assert {:ok, titles_after} = Memory.Global.list()
      refute "To Forget" in titles_after
    end
  end
end

defmodule Cmd.MemoryTest do
  use Fnord.TestCase, async: false

  setup do
    # Ensure global memory storage exists
    :ok = Memory.Global.init()
    :ok
  end

  describe "run/3" do
    @tag :no_project_error
    test "errors when no project selected without --global flag" do
      mem = %Memory{
        scope: :global,
        title: "Global Test",
        slug: Memory.title_to_slug("Global Test"),
        content: "some content",
        topics: ["topic"],
        embeddings: [0.1, 0.2, 0.3]
      }

      assert :ok = Memory.Global.save(mem)

      Services.Globals.put_env(:fnord, :test_no_halt, true)
      on_exit(fn -> Services.Globals.delete_env(:fnord, :test_no_halt) end)

      assert_raise RuntimeError,
                   ~r/No project selected/,
                   fn ->
                     Cmd.Memory.run(%{}, [], [])
                   end
    end

    test "supports filtering by scope (global)" do
      mem = %Memory{
        scope: :global,
        title: "Only Global",
        slug: Memory.title_to_slug("Only Global"),
        content: "global content",
        topics: [],
        embeddings: [0.1, 0.2, 0.3]
      }

      assert :ok = Memory.Global.save(mem)

      {stdout, _stderr} = capture_all(fn -> Cmd.Memory.run(%{global: true}, [], []) end)

      assert stdout =~ "## global"
      refute stdout =~ "## project"
      refute stdout =~ "## session"
      assert stdout =~ "### [global] Only Global"
    end

    test "semantic search includes score line in global mode" do
      mem = %Memory{
        scope: :global,
        title: "Scored",
        slug: Memory.title_to_slug("Scored"),
        content: "queryable content",
        topics: [],
        embeddings: [1.0, 2.0, 3.0]
      }

      assert :ok = Memory.Global.save(mem)

      # StubIndexer.get_embeddings/1 returns [1,2,3] in tests
      {stdout, _stderr} =
        capture_all(fn -> Cmd.Memory.run(%{global: true, query: "anything"}, [], []) end)

      assert stdout =~ "### Scored"
      assert stdout =~ "_Score:_ "
      assert stdout =~ "queryable content"
    end
  end
end

defmodule Cmd.MemoryTest do
  use Fnord.TestCase, async: false

  # The stub indexer returns List.duplicate(0.1, 384) for query embeddings.
  # These helpers produce 384-dim vectors with known cosine similarity to that.
  defp stub_vec(), do: List.duplicate(0.1, 384)

  # Cosine similarity ~0.7 with the stub vector
  defp partial_match_vec() do
    matching = List.duplicate(0.1, 192)
    orthogonal = List.duplicate(0.0, 192)
    matching ++ orthogonal
  end

  # Cosine similarity < 0 with the stub vector (negative direction)
  defp weak_vec(), do: List.duplicate(-0.1, 384)

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
        embeddings: stub_vec()
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
        embeddings: stub_vec()
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
        embeddings: stub_vec()
      }

      assert :ok = Memory.Global.save(mem)

      {stdout, _stderr} =
        capture_all(fn -> Cmd.Memory.run(%{global: true, query: "anything"}, [], []) end)

      assert stdout =~ "### Scored"
      assert stdout =~ "_Score:_ "
      assert stdout =~ "queryable content"
    end

    test "semantic search filters out weaker matches below the threshold" do
      strongest = %Memory{
        scope: :global,
        title: "Strongest Match",
        slug: Memory.title_to_slug("Strongest Match"),
        content: "strongest content",
        topics: [],
        embeddings: stub_vec()
      }

      still_good = %Memory{
        scope: :global,
        title: "Still Good Match",
        slug: Memory.title_to_slug("Still Good Match"),
        content: "still good content",
        topics: [],
        embeddings: partial_match_vec()
      }

      too_weak = %Memory{
        scope: :global,
        title: "Too Weak Match",
        slug: Memory.title_to_slug("Too Weak Match"),
        content: "too weak content",
        topics: [],
        embeddings: weak_vec()
      }

      assert :ok = Memory.Global.save(strongest)
      assert :ok = Memory.Global.save(still_good)
      assert :ok = Memory.Global.save(too_weak)

      {stdout, _stderr} =
        capture_all(fn -> Cmd.Memory.run(%{global: true, query: "anything"}, [], []) end)

      assert stdout =~ "### Strongest Match"
      assert stdout =~ "### Still Good Match"
      refute stdout =~ "### Too Weak Match"
    end

    test "lists project memories in project mode" do
      project = mock_project("cmd_memory_project_listing")
      File.mkdir_p!(project.store_path)

      mem = %Memory{
        scope: :project,
        title: "Project Listed",
        slug: Memory.title_to_slug("Project Listed"),
        content: "project content",
        topics: ["project"],
        embeddings: stub_vec()
      }

      assert :ok = Memory.Project.init()
      assert :ok = Memory.Project.save(mem)

      {stdout, _stderr} = capture_all(fn -> Cmd.Memory.run(%{}, [], []) end)

      assert stdout =~ "## project"
      assert stdout =~ "### [project] Project Listed"
      assert stdout =~ "project content"
    end
  end
end

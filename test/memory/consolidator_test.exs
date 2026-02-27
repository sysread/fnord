defmodule Memory.ConsolidatorTest do
  use Fnord.TestCase, async: false

  alias Services.MemoryConsolidation

  describe "MemoryConsolidation" do
    test "checkout returns :done for empty memory list" do
      {:ok, pool} = MemoryConsolidation.start_link([])
      assert :done = MemoryConsolidation.checkout(pool)
      GenServer.stop(pool)
    end

    test "checkout skips memories with no candidates" do
      # Two memories with orthogonal embeddings — no similarity above floor.
      a = %Memory{
        scope: :project,
        title: "Alpha",
        slug: "alpha",
        content: "content a",
        embeddings: [1.0, 0.0, 0.0, 0.0, 0.0]
      }

      b = %Memory{
        scope: :project,
        title: "Beta",
        slug: "beta",
        content: "content b",
        embeddings: [0.0, 0.0, 0.0, 0.0, 1.0]
      }

      {:ok, pool} = MemoryConsolidation.start_link([a, b])

      # Both should be skipped (no candidates above floor).
      assert {:skip, _} = MemoryConsolidation.checkout(pool)
      assert {:skip, _} = MemoryConsolidation.checkout(pool)
      assert :done = MemoryConsolidation.checkout(pool)

      report = MemoryConsolidation.report(pool)
      assert report.kept == 2
      GenServer.stop(pool)
    end

    test "checkout returns candidates for similar memories" do
      emb = List.duplicate(1.0, 10)

      a = %Memory{
        scope: :global,
        title: "First",
        slug: "first",
        content: "content",
        embeddings: emb
      }

      b = %Memory{
        scope: :global,
        title: "Second",
        slug: "second",
        content: "content",
        embeddings: emb
      }

      {:ok, pool} = MemoryConsolidation.start_link([a, b])

      # First checkout gets one memory with the other as candidate.
      assert {:ok, focus, candidates} = MemoryConsolidation.checkout(pool)
      assert length(candidates) == 1
      assert hd(candidates).tier == "high"

      # Complete with no eaten slugs.
      MemoryConsolidation.complete(pool, focus, {:ok, []})

      # Second checkout — the other memory. Its candidate (the first) is no
      # longer remaining, so it gets skipped.
      assert {:skip, _} = MemoryConsolidation.checkout(pool)
      assert :done = MemoryConsolidation.checkout(pool)

      GenServer.stop(pool)
    end

    test "complete removes eaten slugs from remaining" do
      emb = List.duplicate(1.0, 10)

      a = %Memory{scope: :project, title: "A", slug: "a", content: "a", embeddings: emb}
      b = %Memory{scope: :project, title: "B", slug: "b", content: "b", embeddings: emb}
      c = %Memory{scope: :project, title: "C", slug: "c", content: "c", embeddings: emb}

      {:ok, pool} = MemoryConsolidation.start_link([a, b, c])

      # First worker checks out A, eats B.
      {:ok, focus, _candidates} = MemoryConsolidation.checkout(pool)
      MemoryConsolidation.complete(pool, focus, {:ok, [{:project, "b"}]})

      report = MemoryConsolidation.report(pool)
      assert report.merged == 1
      assert report.kept == 1

      GenServer.stop(pool)
    end
  end
end

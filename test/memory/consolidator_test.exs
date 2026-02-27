defmodule Memory.ConsolidatorTest do
  use Fnord.TestCase, async: false

  test "find_candidates returns empty list when focus has no embeddings" do
    focus = %Memory{
      scope: :project,
      title: "Focus",
      slug: "focus",
      content: "some content",
      embeddings: nil
    }

    assert Memory.Consolidator.find_candidates(focus, [], MapSet.new()) == []
  end

  test "find_candidates excludes self and already-processed memories" do
    emb_a = List.duplicate(1.0, 10)
    emb_b = List.duplicate(1.0, 10)
    emb_c = List.duplicate(0.0, 10)

    focus = %Memory{
      scope: :project,
      title: "A",
      slug: "a",
      content: "content a",
      embeddings: emb_a
    }

    same = %Memory{
      scope: :project,
      title: "B",
      slug: "b",
      content: "content b",
      embeddings: emb_b
    }

    different = %Memory{
      scope: :project,
      title: "C",
      slug: "c",
      content: "content c",
      embeddings: emb_c
    }

    all = [focus, same, different]
    processed = MapSet.new()

    candidates = Memory.Consolidator.find_candidates(focus, all, processed)

    # Should find B (identical embeddings, score=1.0) but not self (A) and
    # not C (zero vector → cosine similarity is 0.0, below floor)
    assert length(candidates) == 1
    assert hd(candidates).memory.title == "B"
    assert hd(candidates).tier == "high"
  end

  test "find_candidates respects processed set" do
    emb = List.duplicate(1.0, 10)

    focus = %Memory{scope: :project, title: "A", slug: "a", content: "a", embeddings: emb}
    other = %Memory{scope: :project, title: "B", slug: "b", content: "b", embeddings: emb}

    # B is already processed
    processed = MapSet.new([{:project, "b"}])

    candidates = Memory.Consolidator.find_candidates(focus, [focus, other], processed)
    assert candidates == []
  end

  test "find_candidates returns candidates sorted by score descending" do
    # Create embeddings with varying similarity to focus
    focus_emb = [1.0, 0.0, 0.0, 0.0, 0.0]
    high_emb = [0.9, 0.4, 0.0, 0.0, 0.0]
    mid_emb = [0.6, 0.8, 0.0, 0.0, 0.0]

    focus = %Memory{scope: :global, title: "F", slug: "f", content: "f", embeddings: focus_emb}
    high = %Memory{scope: :global, title: "H", slug: "h", content: "h", embeddings: high_emb}
    mid = %Memory{scope: :global, title: "M", slug: "m", content: "m", embeddings: mid_emb}

    candidates = Memory.Consolidator.find_candidates(focus, [focus, high, mid], MapSet.new())

    # Both should be above the floor; high should come first
    assert length(candidates) == 2
    assert hd(candidates).memory.title == "H"
  end
end

defmodule Memory.ConsolidatorTest do
  use Fnord.TestCase, async: false

  alias Memory.ProjectOwnership
  alias Services.MemoryConsolidation

  describe "MemoryConsolidation" do
    test "checkout returns :done for empty memory list" do
      {:ok, pool} = MemoryConsolidation.start_link([])
      assert :done = MemoryConsolidation.checkout(pool)
      GenServer.stop(pool)
    end

    test "checkout skips memories with no candidates" do
      # Two memories with orthogonal embeddings -- no similarity above floor.
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

      # Second checkout -- the other memory. Its candidate (the first) is no
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

    test "complete records propagated worker errors without merging" do
      emb = List.duplicate(1.0, 10)

      a = %Memory{scope: :project, title: "A", slug: "a", content: "a", embeddings: emb}
      b = %Memory{scope: :project, title: "B", slug: "b", content: "b", embeddings: emb}

      {:ok, pool} = MemoryConsolidation.start_link([a, b])

      assert {:ok, focus, candidates} = MemoryConsolidation.checkout(pool)
      assert length(candidates) == 1

      MemoryConsolidation.complete(pool, focus, {:error, []})

      report = MemoryConsolidation.report(pool)
      assert report.errors == 1
      assert report.merged == 0

      GenServer.stop(pool)
    end
  end

  describe "Memory.ScopePolicy" do
    test "allowed_scopes_for_title/1 allows only global scope for Me" do
      assert Memory.ScopePolicy.allowed_scopes_for_title("Me") == [:global]
    end

    test "automatic_move_candidate?/1 is false for a global Me memory" do
      memory = %Memory{
        scope: :global,
        title: "Me",
        slug: "me",
        content: "Personal profile and preferences that should stay globally scoped.",
        embeddings: [1.0, 2.0, 3.0]
      }

      refute Memory.ScopePolicy.automatic_move_candidate?(memory)
    end

    test "automatic_move_candidate?/1 is false for a vague global memory without enough project signals" do
      memory = %Memory{
        scope: :global,
        title: "Team principles",
        slug: "team-principles",
        content: "General collaboration guidance for planning and communication.",
        embeddings: List.duplicate(0.1, 10)
      }

      refute Memory.ScopePolicy.automatic_move_candidate?(memory)
    end

    test "automatic_move_candidate?/1 is true for a non-reserved global memory with multiple project signals" do
      memory = %Memory{
        scope: :global,
        title: "Memory.Consolidator mix workflow for lib/memory/consolidator.ex",
        slug: "memory-consolidator-mix-workflow-lib-memory-consolidator-ex",
        content:
          "Project scope notes for alpha cover Memory.Consolidator changes in lib/memory/consolidator.ex, mix test workflow updates, and project-to-global scope decisions.",
        embeddings: List.duplicate(0.9, 10)
      }

      assert Memory.ScopePolicy.automatic_move_candidate?(memory)
    end
  end

  describe "Memory.ProjectOwnership" do
    test "suspicious_global_memory?/1 is positive for project-like global memories with multiple signals" do
      memory = %Memory{
        scope: :global,
        title: "Memory.Consolidator mix workflow for lib/memory/consolidator.ex",
        slug: "memory-consolidator-mix-workflow-lib-memory-consolidator-ex",
        content:
          "Project scope notes for alpha cover Memory.Consolidator changes in lib/memory/consolidator.ex, mix test workflow updates, and project-to-global scope decisions.",
        embeddings: List.duplicate(0.9, 10)
      }

      assert ProjectOwnership.suspicious_global_memory?(memory)
    end

    test "suspicious_global_memory?/1 is negative for a global memory with only one weak project signal" do
      memory = %Memory{
        scope: :global,
        title: "Alpha thoughts",
        slug: "alpha-thoughts",
        content: "General planning notes for later.",
        embeddings: List.duplicate(0.1, 10)
      }

      refute ProjectOwnership.suspicious_global_memory?(memory)
    end

    test "suspicious_global_memory?/1 is negative for ordinary global memories" do
      memory = %Memory{
        scope: :global,
        title: "Team principles",
        slug: "team-principles",
        content: "General collaboration guidance for planning and communication.",
        embeddings: List.duplicate(0.1, 10)
      }

      refute ProjectOwnership.suspicious_global_memory?(memory)
    end

    test "classify/1 returns structured ownership details when project notes strongly match" do
      project = mock_project("alpha")

      File.mkdir_p!(project.store_path)

      File.write!(
        Path.join(project.store_path, "notes.md"),
        """
        Alpha cache invalidation plan
        Release blocker investigation
        Deploy sequencing and rollback notes
        """
      )

      memory = %Memory{
        scope: :global,
        title: "Alpha cache invalidation",
        slug: "alpha-cache-invalidation",
        content: "Release blocker caused by cache invalidation during deploy sequencing.",
        embeddings: [1.0, 2.0, 3.0]
      }

      assert {:ok, verdict} = ProjectOwnership.classify(memory)
      assert verdict.project == project.name
      assert verdict.confident == true
    end

    test "classify/1 is inconclusive when project notes are absent" do
      project = mock_project("alpha")
      File.mkdir_p!(project.store_path)

      memory = %Memory{
        scope: :global,
        title: "Alpha cache invalidation",
        slug: "alpha-cache-invalidation",
        content: "Release blocker caused by cache invalidation during deploy sequencing.",
        embeddings: [1.0, 2.0, 3.0]
      }

      assert :inconclusive = ProjectOwnership.classify(memory)
    end

    test "classify/1 is inconclusive when notes are ambiguous" do
      alpha = mock_project("alpha")
      beta = mock_project("beta")

      File.mkdir_p!(alpha.store_path)
      File.mkdir_p!(beta.store_path)

      notes = "Shared cache invalidation rollout and deploy sequencing guidance"
      File.write!(Path.join(alpha.store_path, "notes.md"), notes)
      File.write!(Path.join(beta.store_path, "notes.md"), notes)

      memory = %Memory{
        scope: :global,
        title: "Cache invalidation rollout",
        slug: "cache-invalidation-rollout",
        content: "Shared deploy sequencing guidance for cache invalidation rollout.",
        embeddings: [1.0, 2.0, 3.0]
      }

      assert :inconclusive = ProjectOwnership.classify(memory)
    end

    test "move_to_project/2 writes a project-scoped copy and removes the global memory" do
      project = mock_project("alpha")
      File.mkdir_p!(project.store_path)
      :ok = Memory.Project.init()

      memory = %Memory{
        scope: :global,
        title: "Alpha cache invalidation",
        slug: "alpha-cache-invalidation",
        content: "Release blocker caused by cache invalidation during deploy sequencing.",
        embeddings: [1.0, 2.0, 3.0]
      }

      assert {:ok, saved} = Memory.save(memory)
      assert {:ok, _} = Memory.read(:global, saved.title)

      assert {:ok, moved} = ProjectOwnership.move_to_project(saved, project.name)
      assert moved.scope == :project
      assert moved.slug == memory.slug
      assert {:error, :not_found} = Memory.read(:global, saved.title)
      assert {:ok, project_copy} = Memory.read(:project, moved.title)
      assert project_copy.scope == :project
    end

    test "suspicious global memories can be moved through the ownership path without crashing coordinator flow" do
      project = mock_project("alpha")
      File.mkdir_p!(project.store_path)
      :ok = Memory.Project.init()

      File.write!(
        Path.join(project.store_path, "notes.md"),
        """
        Alpha cache invalidation plan
        Release blocker investigation
        Deploy sequencing and rollback notes
        """
      )

      memory = %Memory{
        scope: :global,
        title: "Alpha cache invalidation",
        slug: "alpha-cache-invalidation",
        content: "Release blocker caused by cache invalidation during deploy sequencing.",
        embeddings: [1.0, 2.0, 3.0]
      }

      assert {:ok, saved} = Memory.save(memory)
      {:ok, pool} = MemoryConsolidation.start_link([saved])

      result =
        case MemoryConsolidation.checkout(pool) do
          {:ok, focus, _candidates} ->
            assert {:ok, verdict} = ProjectOwnership.classify(focus)
            assert {:ok, moved} = ProjectOwnership.move_to_project(focus, project.name)
            MemoryConsolidation.complete(pool, focus, {:ok, []})
            {:moved, verdict, moved}

          {:skip, focus} ->
            assert {:ok, verdict} = ProjectOwnership.classify(focus)
            assert {:ok, moved} = ProjectOwnership.move_to_project(focus, project.name)
            MemoryConsolidation.complete(pool, focus, {:ok, []})
            {:moved, verdict, moved}
        end

      assert {:moved, verdict, moved} = result
      assert verdict.project == project.name
      assert moved.scope == :project
      assert :done = MemoryConsolidation.checkout(pool)

      report = MemoryConsolidation.report(pool)
      assert report.merged == 0

      assert {:ok, _project_copy} = Memory.read(:project, moved.title)
      assert {:error, :not_found} = Memory.read(:global, saved.title)

      GenServer.stop(pool)
    end

    test "scope policy allows only global scope for Me" do
      assert Memory.ScopePolicy.allowed_scopes_for_title("Me") == [:global]
    end

    test "move_to_project/2 rejects moving Me with invalid target scope" do
      project = mock_project("alpha")
      File.mkdir_p!(project.store_path)
      :ok = Memory.Project.init()

      memory = %Memory{
        scope: :global,
        title: "Me",
        slug: "me",
        content: "Personal profile and preferences that should stay globally scoped.",
        embeddings: [1.0, 2.0, 3.0]
      }

      assert {:ok, saved} = Memory.save(memory)

      assert {:error, :invalid_target_scope} =
               ProjectOwnership.move_to_project(saved, project.name)

      assert {:ok, _global_copy} = Memory.read(:global, saved.title)
      assert {:error, :not_found} = Memory.read(:project, saved.title)
    end

    test "ownership path keeps Me global even when notes and content would otherwise suggest a move" do
      project = mock_project("alpha")
      File.mkdir_p!(project.store_path)
      :ok = Memory.Project.init()

      File.write!(
        Path.join(project.store_path, "notes.md"),
        """
        Me cache invalidation plan
        Release blocker investigation
        Deploy sequencing and rollback notes
        """
      )

      memory = %Memory{
        scope: :global,
        title: "Me",
        slug: "me",
        content:
          "Release blocker caused by cache invalidation during deploy sequencing for alpha.",
        embeddings: [1.0, 2.0, 3.0]
      }

      assert {:ok, saved} = Memory.save(memory)
      {:ok, pool} = MemoryConsolidation.start_link([saved])

      result =
        case MemoryConsolidation.checkout(pool) do
          {:ok, focus, _candidates} ->
            verdict = ProjectOwnership.classify(focus)
            move_result = ProjectOwnership.move_to_project(focus, project.name)
            MemoryConsolidation.complete(pool, focus, {:ok, []})
            {focus, verdict, move_result}

          {:skip, focus} ->
            verdict = ProjectOwnership.classify(focus)
            move_result = ProjectOwnership.move_to_project(focus, project.name)
            MemoryConsolidation.complete(pool, focus, {:ok, []})
            {focus, verdict, move_result}
        end

      assert {focus, verdict, move_result} = result
      assert focus.title == "Me"
      assert {:error, :invalid_target_scope} = move_result

      case verdict do
        {:ok, %{project: project_name}} -> assert project_name == project.name
        :inconclusive -> :ok
      end

      assert :done = MemoryConsolidation.checkout(pool)

      report = MemoryConsolidation.report(pool)
      assert report.merged == 0
      assert report.kept == 2

      assert {:ok, _global_copy} = Memory.read(:global, saved.title)
      assert {:error, :not_found} = Memory.read(:project, saved.title)

      GenServer.stop(pool)
    end
  end
end

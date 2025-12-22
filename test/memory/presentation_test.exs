defmodule Memory.PresentationTest do
  use Fnord.TestCase, async: true

  alias Memory.Presentation

  defp dt!(iso) do
    {:ok, dt, 0} = DateTime.from_iso8601(iso)
    dt
  end

  describe "age_line/2" do
    test "returns unknown when timestamps missing" do
      mem = %Memory{
        scope: :global,
        title: "X",
        slug: "x",
        content: "c",
        topics: [],
        embeddings: [0.1],
        inserted_at: nil,
        updated_at: nil
      }

      now = dt!("2025-01-01T00:00:00Z")
      assert Presentation.age_line(mem, now) == "Age: unknown (missing timestamps)"
    end

    test "renders age from inserted_at and updated_at" do
      mem = %Memory{
        scope: :global,
        title: "X",
        slug: "x",
        content: "c",
        topics: [],
        embeddings: [0.1],
        inserted_at: "2024-01-01T00:00:00Z",
        updated_at: "2024-12-20T00:00:00Z"
      }

      now = dt!("2025-01-01T00:00:00Z")
      assert Presentation.age_line(mem, now) == "Age: 366 days (updated 12 days ago)"
    end
  end

  describe "warning_line/3" do
    test "returns nil when updated_at missing" do
      mem = %Memory{
        scope: :global,
        title: "X",
        slug: "x",
        content: "c",
        topics: [],
        embeddings: [0.1],
        inserted_at: "2024-01-01T00:00:00Z",
        updated_at: nil
      }

      now = dt!("2025-01-01T00:00:00Z")
      assert Presentation.warning_line(mem, now) == nil
    end

    test "returns mild warning when updated age exceeds mild_days" do
      mem = %Memory{
        scope: :global,
        title: "X",
        slug: "x",
        content: "c",
        topics: [],
        embeddings: [0.1],
        inserted_at: "2024-01-01T00:00:00Z",
        updated_at: "2024-01-01T00:00:00Z"
      }

      now = dt!("2025-01-01T00:00:00Z")

      assert Presentation.warning_line(mem, now, mild_days: 180, strong_days: 999) =~
               "Note: last updated 366 days ago"
    end

    test "returns strong warning when updated age exceeds strong_days" do
      mem = %Memory{
        scope: :global,
        title: "X",
        slug: "x",
        content: "c",
        topics: [],
        embeddings: [0.1],
        inserted_at: "2023-01-01T00:00:00Z",
        updated_at: "2023-01-01T00:00:00Z"
      }

      now = dt!("2025-01-01T00:00:00Z")

      assert Presentation.warning_line(mem, now, mild_days: 180, strong_days: 365) =~
               "Warning: last updated"
    end
  end
end

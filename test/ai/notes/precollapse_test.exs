defmodule AI.Notes.PrecollapseTest do
  use Fnord.TestCase, async: true

  alias AI.Notes

  # Expose the private via a shim to keep tests focused.
  defp collapse(text), do: :erlang.apply(Notes, :collapse_unconsolidated_sections, [text])

  test "(a) no NEW NOTES sections" do
    input = "# HEADER\ncontent\n"
    assert collapse(input) == input
  end

  test "(b) one NEW NOTES with content" do
    input = "# H\nX\n\n# NEW NOTES (unconsolidated)\n- a\n- b\n"

    out = collapse(input)
    assert out =~ "# H\nX\n\n# NEW NOTES (unconsolidated)\n- a\n- b\n"
  end

  test "(c) one NEW NOTES without content" do
    input = "# H\nX\n\n# NEW NOTES (unconsolidated)\n\n# T\nY\n"
    assert collapse(input) == "# H\nX\n\n# T\nY\n"
  end

  test "(d) two NEW NOTES with content merges preserving order, dedup case-insensitive" do
    input =
      "# H\nX\n\n# NEW NOTES (unconsolidated)\n- A\n- b\n\n# M\n\n# NEW NOTES (unconsolidated)\n- a\n- C\n"

    out = collapse(input)
    assert out =~ "# NEW NOTES (unconsolidated)\n- A\n- b\n- C\n"
    # Only one block remains
    assert String.split(out, "# NEW NOTES (unconsolidated)") |> length() == 2
  end

  test "(e) two NEW NOTES without content removes blocks" do
    input =
      "# H\nX\n\n# NEW NOTES (unconsolidated)\n\n# M\n\n# NEW NOTES (unconsolidated)\n\n# Z\n"

    out = collapse(input)
    assert out == "# H\nX\n\n# M\n\n# Z\n"
  end

  test "(f) three NEW NOTES with content collapses into one" do
    input =
      "# A\n\n# NEW NOTES (unconsolidated)\n- one\n\n# B\n\n# NEW NOTES (unconsolidated)\n- two\n\n# C\n\n# NEW NOTES (unconsolidated)\n- two\n- three\n"

    out = collapse(input)
    assert out =~ "# NEW NOTES (unconsolidated)\n- one\n- two\n- three\n"
    assert String.split(out, "# NEW NOTES (unconsolidated)") |> length() == 2
  end

  test "(g) three NEW NOTES without content removes all" do
    input =
      "# A\n\n# NEW NOTES (unconsolidated)\n\n# B\n\n# NEW NOTES (unconsolidated)\n\n# C\n\n# NEW NOTES (unconsolidated)\n\n# D\n"

    out = collapse(input)
    assert out == "# A\n\n# B\n\n# C\n\n# D\n"
  end
end

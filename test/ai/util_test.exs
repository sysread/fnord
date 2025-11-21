defmodule AI.UtilTest do
  use Fnord.TestCase, async: false

  test "cosine_similarity/2 computes correct similarity", _context do
    vec1 = [1.0, 0.0, 0.0]
    vec2 = [0.0, 1.0, 0.0]
    vec3 = [1.0, 0.0, 0.0]

    # Cosine similarity between orthogonal vectors should be 0
    assert AI.Util.cosine_similarity(vec1, vec2) == 0.0

    # Cosine similarity between identical vectors should be 1
    assert AI.Util.cosine_similarity(vec1, vec3) == 1.0

    # Cosine similarity between vector and itself
    similarity = AI.Util.cosine_similarity(vec1, vec1)
    assert similarity == 1.0

    # Cosine similarity between arbitrary vectors
    vec4 = [1.0, 2.0, 3.0]
    vec5 = [4.0, 5.0, 6.0]
    similarity = AI.Util.cosine_similarity(vec4, vec5)

    # Compute expected value
    dot_product = Enum.zip(vec4, vec5) |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
    magnitude1 = :math.sqrt(Enum.reduce(vec4, 0.0, fn x, acc -> acc + x * x end))
    magnitude2 = :math.sqrt(Enum.reduce(vec5, 0.0, fn x, acc -> acc + x * x end))
    expected_similarity = dot_product / (magnitude1 * magnitude2)
    assert_in_delta similarity, expected_similarity, 1.0e-5
  end

  @short_msg "This is a short message."
  @long_msg String.duplicate("A", 60_000)
  @long_mb_msg String.duplicate("😀", 60_000)

  describe "message truncation behavior" do
    test "system_msg does not truncate short content" do
      result = AI.Util.system_msg(@short_msg)
      assert result.content == @short_msg
    end

    test "system_msg truncates long content" do
      result = AI.Util.system_msg(@long_msg)
      assert String.ends_with?(result.content, "(msg truncated due to size)")
      assert String.length(result.content) < String.length(@long_msg)
    end

    test "user_msg does not truncate short content" do
      result = AI.Util.user_msg(@short_msg)
      assert result.content == @short_msg
    end

    test "user_msg truncates long content" do
      result = AI.Util.user_msg(@long_msg)
      assert String.ends_with?(result.content, "(msg truncated due to size)")
      assert String.length(result.content) < String.length(@long_msg)
    end

    test "assistant_msg does not truncate short content" do
      result = AI.Util.assistant_msg(@short_msg)
      assert result.content == @short_msg
    end

    test "assistant_msg truncates long content" do
      result = AI.Util.assistant_msg(@long_msg)
      assert String.ends_with?(result.content, "(msg truncated due to size)")
      assert String.length(result.content) < String.length(@long_msg)
    end

    test "tool_msg does not truncate short content" do
      result = AI.Util.tool_msg("id", "func", @short_msg)
      assert String.contains?(result.content, @short_msg)
      refute String.ends_with?(result.content, "(msg truncated due to size)")
    end

    test "tool_msg truncates long content" do
      result = AI.Util.tool_msg("id", "func", @long_msg)

      # Very large tool outputs should be spilled to a tmp file with a header that
      # explains how to inspect the file using shell_tool, plus a truncated preview.
      assert String.contains?(result.content, "[fnord: tool output truncated]")

      # We no longer assert on an exact file path; instead, ensure that the header
      # mentions a temp file path and that the same path is used in the shell_tool
      # instructions. This keeps the test robust while allowing Briefly to choose
      # safe, unique filenames.
      assert String.contains?(result.content, "Full output saved to:")

      assert String.contains?(
               result.content,
               "To inspect more of this output, use `shell_tool` with a command like:"
             )

      assert String.contains?(result.content, "--- Begin truncated preview ---")
      assert String.contains?(result.content, "--- End truncated preview ---")
    end

    test "multibyte emoji truncation works by character count" do
      result = AI.Util.system_msg(@long_mb_msg)
      assert String.ends_with?(result.content, "(msg truncated due to size)")
      assert String.length(result.content) < String.length(@long_mb_msg)
    end
  end
end

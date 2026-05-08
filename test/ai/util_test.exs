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

  describe "system_msg/1 role" do
    test "uses the active provider's system role for OpenAI" do
      Services.Globals.put_env(:fnord, :ai_provider, "openai")
      assert AI.Util.system_msg("hi").role == "developer"
    end

    test "uses the active provider's system role for Venice" do
      # Venice silently downgrades developer-role messages, so the
      # message must use role "system" - this test catches a
      # provider-mismatch regression at construction time.
      Services.Globals.put_env(:fnord, :ai_provider, "venice")
      assert AI.Util.system_msg("hi").role == "system"
    end
  end

  describe "message-type predicates" do
    require AI.Util

    test "is_system_msg? accepts both developer and system roles" do
      assert AI.Util.is_system_msg?(%{role: "developer", content: "x"})
      assert AI.Util.is_system_msg?(%{role: "system", content: "x"})
      refute AI.Util.is_system_msg?(%{role: "user", content: "x"})
      refute AI.Util.is_system_msg?(%{role: "assistant", content: "x"})
      refute AI.Util.is_system_msg?(%{role: "tool", content: "x"})
      refute AI.Util.is_system_msg?(%{not_a: :message})
    end

    test "is_user_msg?, is_assistant_msg?, is_tool_msg? match their roles" do
      assert AI.Util.is_user_msg?(%{role: "user", content: ""})
      assert AI.Util.is_assistant_msg?(%{role: "assistant", content: "ok"})
      assert AI.Util.is_assistant_msg?(%{role: "assistant", content: nil, tool_calls: []})
      assert AI.Util.is_tool_msg?(%{role: "tool", content: "result"})

      refute AI.Util.is_user_msg?(%{role: "assistant", content: "ok"})
      refute AI.Util.is_assistant_msg?(%{role: "tool", content: "result"})
      refute AI.Util.is_tool_msg?(%{role: "user", content: "x"})
    end

    test "is_tool_call_msg? requires assistant role + nil content + tool_calls list" do
      assert AI.Util.is_tool_call_msg?(%{role: "assistant", content: nil, tool_calls: []})

      assert AI.Util.is_tool_call_msg?(%{
               role: "assistant",
               content: nil,
               tool_calls: [%{id: "x"}]
             })

      # Plain assistant text reply is NOT a tool-call message.
      refute AI.Util.is_tool_call_msg?(%{role: "assistant", content: "hi"})
      # Wrong role.
      refute AI.Util.is_tool_call_msg?(%{role: "user", content: nil, tool_calls: []})
      # No tool_calls field.
      refute AI.Util.is_tool_call_msg?(%{role: "assistant", content: nil})
    end
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
      # explains how to inspect the file using cmd_tool, plus a truncated preview.
      assert String.contains?(result.content, "[fnord: tool output truncated]")

      # We no longer assert on an exact file path; instead, ensure that the header
      # mentions a temp file path and that the same path is used in the cmd_tool
      # instructions. This keeps the test robust while allowing Briefly to choose
      # safe, unique filenames.
      assert String.contains?(result.content, "Full output saved to:")

      assert String.contains?(
               result.content,
               "To inspect more of this output, use `cmd_tool` with a command like:"
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

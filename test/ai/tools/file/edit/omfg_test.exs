defmodule AI.Tools.File.Edit.OMFGTest do
  use ExUnit.Case, async: false
  alias AI.Tools.File.Edit.OMFG

  describe "normalize_agent_chaos/1" do
    test "passes through well-formed parameters unchanged" do
      args = %{
        "file" => "test.ex",
        "changes" => [%{"instructions" => "Add a comment"}]
      }

      assert {:ok, ^args} = OMFG.normalize_agent_chaos(args)
    end

    test "handles top-level patch parameter" do
      args = %{
        "file" => "test.ex",
        "patch" => "Add error handling to the function"
      }

      expected = %{
        "file" => "test.ex",
        "changes" => [%{"instructions" => "Add error handling to the function"}]
      }

      assert {:ok, ^expected} = OMFG.normalize_agent_chaos(args)
    end

    test "handles patch within changes array" do
      args = %{
        "file" => "test.ex",
        "changes" => [
          %{"patch" => "First change"},
          %{"instructions" => "Second change"},
          %{"patch" => "Third change"}
        ]
      }

      expected = %{
        "file" => "test.ex",
        "changes" => [
          %{"instructions" => "First change"},
          %{"instructions" => "Second change"},
          %{"instructions" => "Third change"}
        ]
      }

      assert {:ok, ^expected} = OMFG.normalize_agent_chaos(args)
    end

    test "handles insert_after parameter" do
      args = %{
        "file" => "test.ex",
        "changes" => [
          %{
            "insert_after" => "def main() do",
            "pattern" => "def main() do",
            "content" => "  # Main function implementation"
          }
        ]
      }

      {:ok, result} = OMFG.normalize_agent_chaos(args)

      assert %{
               "file" => "test.ex",
               "changes" => [%{"instructions" => instruction}]
             } = result

      assert String.contains?(instruction, "After def main() do")
      assert String.contains?(instruction, "# Main function implementation")
    end

    test "handles insert_before parameter" do
      args = %{
        "file" => "test.ex",
        "changes" => [
          %{
            "insert_before" => "end",
            "pattern" => "end",
            "content" => "  IO.puts(\"Goodbye\")"
          }
        ]
      }

      {:ok, result} = OMFG.normalize_agent_chaos(args)

      assert %{
               "file" => "test.ex",
               "changes" => [%{"instructions" => instruction}]
             } = result

      assert String.contains?(instruction, "Before end")
      assert String.contains?(instruction, "IO.puts(\"Goodbye\")")
    end

    test "handles context + pattern combination for exact matching" do
      args = %{
        "file" => "test.ex",
        "changes" => [
          %{
            "context" => "within function",
            "pattern" => "old_code_here",
            "content" => "new_code_here"
          }
        ]
      }

      expected = %{
        "file" => "test.ex",
        "changes" => [
          %{
            "old_string" => "old_code_here",
            "new_string" => "new_code_here"
          }
        ]
      }

      assert {:ok, ^expected} = OMFG.normalize_agent_chaos(args)
    end

    test "handles pattern-only without replacement content" do
      args = %{
        "file" => "test.ex",
        "changes" => [
          %{"pattern" => "some_function()"}
        ]
      }

      {:ok, result} = OMFG.normalize_agent_chaos(args)

      assert %{
               "file" => "test.ex",
               "changes" => [%{"instructions" => instruction}]
             } = result

      assert String.contains?(instruction, "some_function()")
    end

    test "handles diff-style patch format" do
      diff_patch = """
      *** Begin Patch
      *** Update File: lib/test.ex
      @@
      -  old_function()
      +  new_function()
      +  additional_line()
      *** End Patch
      """

      args = %{
        "file" => "test.ex",
        "changes" => [%{"instructions" => diff_patch}]
      }

      {:ok, result} = OMFG.normalize_agent_chaos(args)

      assert %{
               "file" => "test.ex",
               "changes" => [%{"instructions" => instruction}]
             } = result

      assert String.contains?(instruction, "Remove:   old_function()")
      assert String.contains?(instruction, "Add:   new_function()")
      assert String.contains?(instruction, "Add:   additional_line()")
    end

    test "handles multiple agent shenanigans in sequence" do
      args = %{
        "file" => "test.ex",
        "patch" => "First change",
        "changes" => [
          %{"insert_after" => "# Comment", "pattern" => "def foo", "content" => "# Comment"},
          %{"context" => "test", "pattern" => "old", "replacement" => "new"}
        ]
      }

      {:ok, result} = OMFG.normalize_agent_chaos(args)

      assert %{
               "file" => "test.ex",
               "changes" => [
                 %{"instructions" => "First change"},
                 %{"instructions" => first_instruction},
                 %{"old_string" => "old", "new_string" => "new"}
               ]
             } = result

      assert String.contains?(first_instruction, "After def foo")
    end

    test "handles empty diff patches gracefully" do
      empty_diff = """
      *** Begin Patch
      @@
      *** End Patch
      """

      args = %{
        "file" => "test.ex",
        "changes" => [%{"instructions" => empty_diff}]
      }

      {:ok, result} = OMFG.normalize_agent_chaos(args)

      assert %{
               "file" => "test.ex",
               "changes" => [%{"instructions" => instruction}]
             } = result

      # Should fallback to using the entire diff as instruction
      assert String.contains?(instruction, "Apply this patch:")
    end

    test "handles agents using replacement instead of content" do
      args = %{
        "file" => "test.ex",
        "changes" => [
          %{
            "context" => "test context",
            "pattern" => "find_this",
            "replacement" => "replace_with_this"
          }
        ]
      }

      expected = %{
        "file" => "test.ex",
        "changes" => [
          %{
            "old_string" => "find_this",
            "new_string" => "replace_with_this"
          }
        ]
      }

      assert {:ok, ^expected} = OMFG.normalize_agent_chaos(args)
    end
  end

  describe "edge cases and combinations" do
    test "rejects non-map entries in changes with a clear error" do
      args = %{"file" => "test.ex", "changes" => ["instructions"]}
      assert {:error, :invalid_argument, _} = AI.Tools.File.Edit.read_args(args)
    end

    test "handles mixed parameter styles within changes array" do
      args = %{
        "file" => "test.ex",
        "changes" => [
          %{"instructions" => "Normal instruction"},
          %{"patch" => "Patch instruction"},
          %{"insert_after" => "function", "content" => "new code"},
          %{"old_string" => "exact", "new_string" => "replacement"}
        ]
      }

      {:ok, result} = OMFG.normalize_agent_chaos(args)

      changes = result["changes"]
      assert length(changes) == 4

      # Should normalize patch and insert_after but leave others alone
      assert Enum.at(changes, 0) == %{"instructions" => "Normal instruction"}
      assert Enum.at(changes, 1) == %{"instructions" => "Patch instruction"}
      assert %{"instructions" => _} = Enum.at(changes, 2)
      assert Enum.at(changes, 3) == %{"old_string" => "exact", "new_string" => "replacement"}
    end

    test "preserves unknown parameters for debugging" do
      # The OMFG module shouldn't break on unknown params, just ignore them
      args = %{
        "file" => "test.ex",
        "changes" => [
          %{
            "mystery_param" => "unknown",
            "instructions" => "Normal instruction"
          }
        ],
        "unknown_top_level" => "also unknown"
      }

      {:ok, result} = OMFG.normalize_agent_chaos(args)

      # Should preserve the unknown params
      assert result["unknown_top_level"] == "also unknown"
      assert get_in(result, ["changes", Access.at(0), "mystery_param"]) == "unknown"
    end
  end
end

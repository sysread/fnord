defmodule AI.AgentTest do
  use Fnord.TestCase, async: false

  describe "validate_standard_opts/1" do
    test "validates correct options with binary instructions and integer conversation" do
      valid_opts = %{
        instructions: "Implement user authentication",
        conversation: 123
      }

      assert :ok = AI.Agent.validate_standard_opts(valid_opts)
    end

    test "rejects empty instructions" do
      opts = %{
        instructions: "",
        conversation: 123
      }

      assert {:error, "Instructions cannot be empty"} = AI.Agent.validate_standard_opts(opts)
    end

    test "rejects whitespace-only instructions" do
      opts = %{
        instructions: "   \n\t  ",
        conversation: 123
      }

      assert {:error, "Instructions cannot be empty"} = AI.Agent.validate_standard_opts(opts)
    end

    test "rejects negative conversation IDs" do
      opts = %{
        instructions: "Valid instructions",
        conversation: -1
      }

      assert {:error, "Conversation ID must be non-negative"} =
               AI.Agent.validate_standard_opts(opts)
    end

    test "accepts zero conversation ID" do
      opts = %{
        instructions: "Valid instructions",
        conversation: 0
      }

      assert :ok = AI.Agent.validate_standard_opts(opts)
    end

    test "rejects missing instructions field" do
      opts = %{
        conversation: 123
      }

      assert {:error, "Missing required field: instructions"} =
               AI.Agent.validate_standard_opts(opts)
    end

    test "rejects missing conversation field" do
      opts = %{
        instructions: "Valid instructions"
      }

      assert {:error, "Missing required field: conversation"} =
               AI.Agent.validate_standard_opts(opts)
    end

    test "rejects non-binary instructions" do
      opts = %{
        instructions: 12345,
        conversation: 123
      }

      assert {:error, "Instructions must be a binary string"} =
               AI.Agent.validate_standard_opts(opts)
    end

    test "rejects non-integer conversation" do
      opts = %{
        instructions: "Valid instructions",
        conversation: "not_an_integer"
      }

      assert {:error, "Conversation ID must be an integer"} =
               AI.Agent.validate_standard_opts(opts)
    end

    test "rejects non-map options" do
      assert {:error, "Options must be a map"} = AI.Agent.validate_standard_opts("not_a_map")
      assert {:error, "Options must be a map"} = AI.Agent.validate_standard_opts([:not, :a, :map])
      assert {:error, "Options must be a map"} = AI.Agent.validate_standard_opts(nil)
    end

    test "handles atom keys correctly" do
      # This tests the internal recursion when we have atom keys
      opts = %{
        instructions: "Valid instructions",
        conversation: 456
      }

      assert :ok = AI.Agent.validate_standard_opts(opts)
    end

    test "handles large conversation IDs" do
      opts = %{
        instructions: "Valid instructions",
        conversation: 999_999_999
      }

      assert :ok = AI.Agent.validate_standard_opts(opts)
    end

    test "handles unicode in instructions" do
      opts = %{
        instructions: "Implement 用户认证 with emoji 🔐",
        conversation: 789
      }

      assert :ok = AI.Agent.validate_standard_opts(opts)
    end

    test "rejects additional unknown fields gracefully" do
      # Should still validate the required fields even with extra ones
      opts = %{
        instructions: "Valid instructions",
        conversation: 123,
        unknown_field: "extra_data",
        another_field: 456
      }

      assert :ok = AI.Agent.validate_standard_opts(opts)
    end
  end

  describe "behavior contract verification" do
    test "defines required callback types" do
      # Verify the behavior defines the expected types
      assert Code.ensure_loaded?(AI.Agent)

      # Check that behavior defines get_response callback
      callbacks = AI.Agent.behaviour_info(:callbacks)
      assert {:get_response, 1} in callbacks

      # Check optional callbacks
      optional_callbacks = AI.Agent.behaviour_info(:optional_callbacks)
      assert {:validate_opts, 1} in optional_callbacks
    end

    test "type specifications are consistent" do
      # This is more of a documentation test to ensure types are defined
      # In a real project you might use a tool like Gradualizer for this

      # Just verify the module has the expected type definitions
      {:docs_v1, _, :elixir, _, _, _, docs} = Code.fetch_docs(AI.Agent)

      # Check that we have documented the expected types
      type_docs = for {{:type, type_name, _arity}, _, _, doc, _} <- docs, do: {type_name, doc}

      type_names = Enum.map(type_docs, fn {name, _doc} -> name end)

      assert :instructions in type_names
      assert :conversation_id in type_names
      assert :agent_opts in type_names
      assert :response in type_names
      assert :error in type_names
    end
  end

  describe "error message clarity" do
    test "provides specific error messages for each validation failure" do
      test_cases = [
        {%{conversation: 123}, "Missing required field: instructions"},
        {%{instructions: "test"}, "Missing required field: conversation"},
        {%{instructions: "", conversation: 123}, "Instructions cannot be empty"},
        {%{instructions: "test", conversation: -1}, "Conversation ID must be non-negative"},
        {%{instructions: 123, conversation: 456}, "Instructions must be a binary string"},
        {%{instructions: "test", conversation: "abc"}, "Conversation ID must be an integer"},
        {"not_a_map", "Options must be a map"}
      ]

      for {opts, expected_error} <- test_cases do
        assert {:error, ^expected_error} = AI.Agent.validate_standard_opts(opts)
      end
    end

    test "error messages are user-friendly" do
      # Test that error messages are clear and actionable  
      # When conversation is invalid type, that's caught first
      opts = %{instructions: "", conversation: "invalid"}

      # Should get the conversation type error first
      assert {:error, "Conversation ID must be an integer"} =
               AI.Agent.validate_standard_opts(opts)

      # Test empty instructions with valid conversation
      opts2 = %{instructions: "", conversation: 123}
      assert {:error, "Instructions cannot be empty"} = AI.Agent.validate_standard_opts(opts2)

      # Error message should not contain technical jargon or internal details
      {:error, error_msg} = AI.Agent.validate_standard_opts("not_a_map")
      refute String.contains?(error_msg, "pattern match")
      refute String.contains?(error_msg, "function clause")
    end
  end

  describe "validation edge cases" do
    test "handles very large instructions" do
      # Test with a very large instruction string
      large_instructions = String.duplicate("x", 100_000)

      opts = %{
        instructions: large_instructions,
        conversation: 123
      }

      assert :ok = AI.Agent.validate_standard_opts(opts)
    end

    test "handles multiline instructions with various whitespace" do
      multiline_instructions = """
      MILESTONE: complex_task

      DESCRIPTION: This is a complex task
      that spans multiple lines and includes
      various types of whitespace.

      RATIONALE: Testing edge cases
      """

      opts = %{
        instructions: multiline_instructions,
        conversation: 456
      }

      assert :ok = AI.Agent.validate_standard_opts(opts)
    end

    test "distinguishes between nil and empty string instructions" do
      # nil instructions should fail with missing field error
      nil_opts = %{conversation: 123}

      assert {:error, "Missing required field: instructions"} =
               AI.Agent.validate_standard_opts(nil_opts)

      # empty string should fail with empty instructions error
      empty_opts = %{instructions: "", conversation: 123}

      assert {:error, "Instructions cannot be empty"} =
               AI.Agent.validate_standard_opts(empty_opts)
    end

    test "handles boundary values for conversation IDs" do
      # Test boundary values
      boundary_cases = [
        # minimum valid value
        0,
        # just above minimum
        1,
        # large positive integer
        2_147_483_647
      ]

      for conversation_id <- boundary_cases do
        opts = %{
          instructions: "Test instructions",
          conversation: conversation_id
        }

        assert :ok = AI.Agent.validate_standard_opts(opts)
      end
    end
  end
end

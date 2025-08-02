defmodule AI.Tools.CoderAgentIsolatedTest do
  use Fnord.TestCase, async: false

  # IMPORTANT: This test module uses meck and must run synchronously
  # to avoid global mock interference between tests

  describe "tool interface compliance (no mocking)" do
    test "implements AI.Tools behavior correctly" do
      tool = AI.Tools.CoderAgent

      assert tool.async?() == false
      assert tool.is_available?() == true

      # Test spec structure
      spec = tool.spec()
      assert spec.type == "function"
      assert spec.function.name == "coder_tool"
      assert spec.function.strict == true

      # Test required parameters
      required = spec.function.parameters.required
      assert "instructions" in required
      assert "conversation_id" in required
    end

    test "read_args parses arguments correctly" do
      valid_args = %{
        "instructions" => "MILESTONE: test\nDESCRIPTION: Test implementation",
        "conversation_id" => "123"
      }

      result = AI.Tools.CoderAgent.read_args(valid_args)

      assert {:ok, parsed} = result
      assert parsed["instructions"] == "MILESTONE: test\nDESCRIPTION: Test implementation"
      assert parsed["conversation_id"] == 123
    end

    test "read_args handles missing arguments" do
      # Missing instructions
      args = %{"conversation_id" => "123"}
      assert {:error, :missing_argument, "instructions"} = AI.Tools.CoderAgent.read_args(args)

      # Missing conversation_id
      args = %{"instructions" => "test"}
      assert {:error, :missing_argument, "conversation_id"} = AI.Tools.CoderAgent.read_args(args)
    end

    test "ui_note_on_request extracts milestone ID" do
      args = %{"instructions" => "MILESTONE: user_auth\nDESCRIPTION: Implement authentication"}

      {title, description} = AI.Tools.CoderAgent.ui_note_on_request(args)

      assert title == "Executing Milestone"
      assert description == "Delegating user_auth to coder agent"
    end

    test "ui_note_on_result indicates success or failure" do
      # Test success case
      success_result = "Milestone completed successfully. All tasks finished."
      {title, description} = AI.Tools.CoderAgent.ui_note_on_result(%{}, success_result)

      assert title == "Milestone Completed"
      assert description == "Coder agent finished successfully"

      # Test error case
      error_result = "Milestone failed with error: compilation issue"
      {title, description} = AI.Tools.CoderAgent.ui_note_on_result(%{}, error_result)

      assert title == "Milestone Failed"
      assert description == "Coder agent encountered errors"
    end
  end

  # Single test that uses mocking - carefully isolated
  describe "agent delegation with controlled mocking" do
    test "validates agent options before delegation - mocked validation only" do
      # This test carefully mocks only the validation step to test error propagation
      # without executing the full agent workflow

      # Setup mocking - ensure we clean up even if test fails
      :meck.new(AI.Agent, [:passthrough])

      try do
        # Mock validation failure only
        :meck.expect(AI.Agent, :validate_standard_opts, fn _opts ->
          {:error, "Instructions cannot be empty"}
        end)

        args = %{
          "instructions" => "",
          "conversation_id" => 123
        }

        result = AI.Tools.CoderAgent.call(args)

        # Should propagate validation error correctly
        assert {:error, "Invalid coder agent request: Instructions cannot be empty"} = result

        # Verify validation was called
        assert :meck.called(AI.Agent, :validate_standard_opts, :_)
      after
        # Always clean up mocks
        :meck.unload(AI.Agent)
      end
    end
  end

  describe "error handling without mocking" do
    test "handles malformed arguments gracefully" do
      # Test argument parsing errors without needing to mock agent execution
      args = %{
        "instructions" => "test",
        "conversation_id" => "not_a_number"
      }

      # Should raise during argument parsing, before any agent calls
      assert_raise ArgumentError, fn ->
        AI.Tools.CoderAgent.read_args(args)
      end
    end

    test "validates instruction format expectations" do
      # Test that we can validate instruction format without full execution
      milestone_instructions = """
      MILESTONE: user_authentication
      DESCRIPTION: Implement user login and registration
      RATIONALE: Core security functionality needed before other features
      ORIGINAL REQUEST: Build a user management system
      """

      args = %{
        "instructions" => milestone_instructions,
        "conversation_id" => "789"
      }

      # Should parse successfully
      assert {:ok, parsed} = AI.Tools.CoderAgent.read_args(args)
      assert String.contains?(parsed["instructions"], "MILESTONE: user_authentication")
      assert String.contains?(parsed["instructions"], "DESCRIPTION:")
      assert parsed["conversation_id"] == 789
    end
  end

  describe "contract compliance verification" do
    test "tool call structure matches expected format" do
      # Verify the tool's call/1 function exists and has correct arity
      exports = AI.Tools.CoderAgent.__info__(:functions)
      assert {:call, 1} in exports
      assert {:read_args, 1} in exports
      assert {:spec, 0} in exports
      assert {:ui_note_on_request, 1} in exports
      assert {:ui_note_on_result, 2} in exports
    end

    test "spec defines correct tool contract" do
      spec = AI.Tools.CoderAgent.spec()

      # Verify contract structure
      assert spec.function.parameters.type == "object"
      assert spec.function.parameters.additionalProperties == false

      # Verify parameter specifications
      properties = spec.function.parameters.properties
      assert Map.has_key?(properties, :instructions)
      assert Map.has_key?(properties, :conversation_id)

      # Verify parameter types
      assert properties[:instructions].type == "string"
      assert properties[:conversation_id].type == "string"
    end
  end
end

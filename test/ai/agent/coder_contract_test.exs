defmodule AI.Agent.CoderContractTest do
  use Fnord.TestCase, async: true

  describe "agent contract compliance" do
    test "validates required options structure" do
      # Valid options should pass validation
      valid_opts = %{
        instructions: "MILESTONE: test\nImplement feature",
        conversation: "uuid-test"
      }
      
      assert :ok = AI.Agent.validate_standard_opts(valid_opts)
    end

    test "rejects invalid option structures" do
      # Missing instructions
      assert {:error, _} = AI.Agent.validate_standard_opts(%{conversation: "uuid-123"})
      
      # Missing conversation
      assert {:error, _} = AI.Agent.validate_standard_opts(%{instructions: "test"})
      
      # Empty instructions
      assert {:error, _} = AI.Agent.validate_standard_opts(%{instructions: "", conversation: "uuid-456"})
      
      # Invalid conversation type
      assert {:error, _} = AI.Agent.validate_standard_opts(%{instructions: "test", conversation: 123})
    end

    test "implements AI.Agent behavior" do
      # Verify the module implements the required behavior
      behaviors = AI.Agent.Coder.__info__(:attributes)[:behaviour] || []
      assert AI.Agent in behaviors
    end

    test "defines required callback functions" do
      # Verify get_response/1 is exported
      exports = AI.Agent.Coder.__info__(:functions)
      assert {:get_response, 1} in exports
    end
  end

  describe "error handling contracts" do
    test "get_response returns proper error format for invalid options" do
      # Test with missing instructions
      invalid_opts = %{conversation: "uuid-test"}
      
      result = AI.Agent.Coder.get_response(invalid_opts)
      
      # Should return error tuple with descriptive message
      assert {:error, error_message} = result
      assert is_binary(error_message)
      assert String.contains?(error_message, "Invalid agent options")
    end

    test "get_response returns proper error format for empty instructions" do
      invalid_opts = %{
        instructions: "",
        conversation: "uuid-empty"
      }
      
      result = AI.Agent.Coder.get_response(invalid_opts)
      
      assert {:error, error_message} = result
      assert String.contains?(error_message, "Instructions cannot be empty")
    end

    test "get_response returns proper error format for invalid conversation" do
      invalid_opts = %{
        instructions: "Valid instructions",
        conversation: ""
      }
      
      result = AI.Agent.Coder.get_response(invalid_opts)
      
      assert {:error, error_message} = result
      assert String.contains?(error_message, "Conversation ID cannot be empty")
    end
  end

  describe "instruction format validation" do
    test "accepts well-formed milestone instructions" do
      milestone_instructions = """
      MILESTONE: user_authentication
      DESCRIPTION: Implement user login and registration
      RATIONALE: Core security functionality needed before other features
      ORIGINAL REQUEST: Build a user management system
      """
      
      opts = %{
        instructions: milestone_instructions,
        conversation: "uuid-milestone"
      }
      
      assert :ok = AI.Agent.validate_standard_opts(opts)
    end

    test "accepts minimal valid instructions" do
      opts = %{
        instructions: "Implement simple feature",
        conversation: "uuid-simple"
      }
      
      assert :ok = AI.Agent.validate_standard_opts(opts)
    end

    test "handles unicode and special characters in instructions" do
      opts = %{
        instructions: "Implement feature with unicode: 用户认证 and symbols: @#$%",
        conversation: "uuid-unicode"
      }
      
      assert :ok = AI.Agent.validate_standard_opts(opts)
    end

    test "rejects whitespace-only instructions" do
      opts = %{
        instructions: "   \n\t   ",
        conversation: "uuid-whitespace"
      }
      
      assert {:error, "Instructions cannot be empty"} = AI.Agent.validate_standard_opts(opts)
    end
  end
end
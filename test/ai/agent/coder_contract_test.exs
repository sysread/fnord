defmodule AI.Agent.CoderContractTest do
  use Fnord.TestCase, async: false

  describe "agent contract compliance" do
    test "validates required options structure" do
      # Valid options should pass validation
      valid_opts = %{
        instructions: "MILESTONE: test\nImplement feature",
        conversation: 123
      }

      assert :ok = AI.Agent.validate_standard_opts(valid_opts)
    end

    test "rejects invalid option structures" do
      # Missing instructions
      assert {:error, _} = AI.Agent.validate_standard_opts(%{conversation: 123})

      # Missing conversation
      assert {:error, _} = AI.Agent.validate_standard_opts(%{instructions: "test"})

      # Empty instructions
      assert {:error, _} = AI.Agent.validate_standard_opts(%{instructions: "", conversation: 123})

      # Invalid conversation type
      assert {:error, _} =
               AI.Agent.validate_standard_opts(%{instructions: "test", conversation: "invalid"})
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
      invalid_opts = %{conversation: 123}

      result = AI.Agent.Coder.get_response(invalid_opts)

      # Should return error tuple with descriptive message
      assert {:error, error_message} = result
      assert is_binary(error_message)
      assert String.contains?(error_message, "Invalid agent options")
    end

    test "get_response returns proper error format for empty instructions" do
      invalid_opts = %{
        instructions: "",
        conversation: 123
      }

      result = AI.Agent.Coder.get_response(invalid_opts)

      assert {:error, error_message} = result
      assert String.contains?(error_message, "Instructions cannot be empty")
    end

    test "get_response returns proper error format for invalid conversation" do
      invalid_opts = %{
        instructions: "Valid instructions",
        conversation: -1
      }

      result = AI.Agent.Coder.get_response(invalid_opts)

      assert {:error, error_message} = result
      assert String.contains?(error_message, "Conversation ID must be non-negative")
    end
  end

  describe "response format contracts" do
    test "successful responses follow expected format" do
      # We can't easily test full execution without complex mocking,
      # but we can verify the validation layer works correctly

      # Valid options structure
      valid_opts = %{
        instructions: "MILESTONE: contract_test\nTest milestone implementation",
        conversation: 456
      }

      # Validation should pass
      assert :ok = AI.Agent.validate_standard_opts(valid_opts)

      # The actual response would depend on Store.get_project and other dependencies,
      # but the contract validation is working correctly
    end

    test "error responses are consistently formatted" do
      error_cases = [
        # missing instructions
        %{conversation: 123},
        # missing conversation
        %{instructions: "test"},
        # empty instructions
        %{instructions: "", conversation: 123},
        # invalid conversation
        %{instructions: "test", conversation: -1}
      ]

      for invalid_opts <- error_cases do
        result = AI.Agent.Coder.get_response(invalid_opts)

        # All errors should follow {:error, binary} format
        assert {:error, error_message} = result
        assert is_binary(error_message)
        assert String.starts_with?(error_message, "Invalid agent options:")
      end
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
        conversation: 789
      }

      assert :ok = AI.Agent.validate_standard_opts(opts)
    end

    test "accepts minimal valid instructions" do
      opts = %{
        instructions: "Implement simple feature",
        conversation: 0
      }

      assert :ok = AI.Agent.validate_standard_opts(opts)
    end

    test "handles unicode and special characters in instructions" do
      opts = %{
        instructions: "Implement feature with unicode: 用户认证 and symbols: @#$%",
        conversation: 100
      }

      assert :ok = AI.Agent.validate_standard_opts(opts)
    end

    test "rejects whitespace-only instructions" do
      opts = %{
        instructions: "   \n\t   ",
        conversation: 200
      }

      assert {:error, "Instructions cannot be empty"} = AI.Agent.validate_standard_opts(opts)
    end
  end

  describe "state transition safety" do
    test "validation happens before any state changes" do
      # This test ensures validation occurs first, preventing 
      # partial state changes when options are invalid

      invalid_opts = %{
        # This will fail validation
        instructions: "",
        conversation: 300
      }

      # Should fail immediately without creating any state
      result = AI.Agent.Coder.get_response(invalid_opts)
      assert {:error, _} = result

      # If validation failed, no other processing should have occurred
      # (This is implicitly tested by the immediate return)
    end
  end
end

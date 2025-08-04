defmodule AI.ErrorFlowValidationTest do
  use Fnord.TestCase, async: true

  @moduledoc """
  Tests error flow validation and state transition safety without complex mocking.

  This test suite focuses on the contract validation and error propagation
  patterns identified in fnord's self-review, while avoiding the complexity
  and potential side effects of extensive mocking.
  """

  describe "agent validation contracts" do
    test "AI.Agent.validate_standard_opts handles all error cases" do
      # Test each validation failure path
      error_cases = [
        # Missing fields
        {%{conversation: "uuid-123"}, "Missing required field: instructions"},
        {%{instructions: "test"}, "Missing required field: conversation"},

        # Invalid types
        {%{instructions: 123, conversation: "uuid-456"}, "Instructions must be a binary string"},
        {%{instructions: "test", conversation: 123}, "Conversation ID must be a binary string"},

        # Invalid values
        {%{instructions: "", conversation: "uuid-789"}, "Instructions cannot be empty"},
        {%{instructions: "   \n\t  ", conversation: "uuid-abc"}, "Instructions cannot be empty"},
        {%{instructions: "test", conversation: ""}, "Conversation ID cannot be empty"},

        # Non-map input
        {"not_a_map", "Options must be a map"},
        {nil, "Options must be a map"},
        {[], "Options must be a map"}
      ]

      for {invalid_opts, expected_error} <- error_cases do
        result = AI.Agent.validate_standard_opts(invalid_opts)
        assert {:error, ^expected_error} = result
      end
    end

    test "AI.Agent.validate_standard_opts accepts valid inputs" do
      valid_cases = [
        %{instructions: "Simple task", conversation: "uuid-0"},
        %{instructions: "Complex\nmultiline\ninstructions", conversation: "uuid-123"},
        %{instructions: "Unicode: 用户认证 🔐", conversation: "uuid-999"},
        %{instructions: "Very long " <> String.duplicate("x", 10000), conversation: "uuid-1"},
        %{instructions: "MILESTONE: test\nDESCRIPTION: formatted", conversation: "uuid-42"}
      ]

      for valid_opts <- valid_cases do
        assert :ok = AI.Agent.validate_standard_opts(valid_opts)
      end
    end
  end

  describe "coder agent error propagation" do
    test "get_response propagates validation errors correctly" do
      # Test that AI.Agent.Coder.get_response properly validates and returns errors
      # without requiring full agent execution

      validation_error_cases = [
        # missing instructions
        %{conversation: "uuid-123"},
        # missing conversation
        %{instructions: "test"},
        # empty instructions
        %{instructions: "", conversation: "uuid-456"},
        # empty conversation
        %{instructions: "test", conversation: ""}
      ]

      for invalid_opts <- validation_error_cases do
        result = AI.Agent.Coder.get_response(invalid_opts)

        # Should return error tuple with descriptive message
        assert {:error, error_message} = result
        assert is_binary(error_message)
        assert String.starts_with?(error_message, "Invalid agent options:")
      end
    end

    test "get_response accepts valid options structure" do
      # We can't test full execution without Store.get_project and other dependencies,
      # but we can verify the validation layer works correctly

      valid_opts = %{
        instructions: "MILESTONE: validation_test\nTest validation flow",
        conversation: "uuid-validation"
      }

      # Validation should pass (the actual response will depend on Store state)
      assert :ok = AI.Agent.validate_standard_opts(valid_opts)
    end
  end

  describe "tool argument validation" do
    test "CoderAgent.read_args validates required arguments" do
      # Missing arguments
      assert {:error, :missing_argument, "instructions"} =
               AI.Tools.CoderAgent.read_args(%{"conversation_id" => "123"})

      assert {:error, :missing_argument, "conversation_id"} =
               AI.Tools.CoderAgent.read_args(%{"instructions" => "test"})
    end

    test "CoderAgent.read_args handles type conversion errors" do
      # Invalid conversation_id format should raise during conversion
      args = %{
        "instructions" => "test",
        "conversation_id" => "not_a_number"
      }

      # Should parse successfully since we no longer convert to integer
      assert {:ok, parsed} = AI.Tools.CoderAgent.read_args(args)
      assert parsed["conversation_id"] == "not_a_number"
    end

    test "CoderAgent.read_args succeeds with valid arguments" do
      valid_args = %{
        "instructions" => "MILESTONE: test\nImplement feature",
        "conversation_id" => "456"
      }

      assert {:ok, parsed} = AI.Tools.CoderAgent.read_args(valid_args)
      assert parsed["instructions"] == "MILESTONE: test\nImplement feature"
      assert parsed["conversation_id"] == "456"
    end
  end

  describe "state transition safety" do
    test "validation occurs before state changes in agent workflow" do
      # This test verifies that validation happens first in the agent workflow,
      # preventing partial state changes when options are invalid

      invalid_opts = %{
        # This will fail validation
        instructions: "",
        conversation: "uuid-statetest"
      }

      # Should fail immediately during validation, before any state creation
      result = AI.Agent.Coder.get_response(invalid_opts)
      assert {:error, _} = result

      # The error should be a validation error, not a runtime error from
      # attempting to create state with invalid options
      {:error, error_message} = result
      assert String.contains?(error_message, "Instructions cannot be empty")
    end

    test "TaskServer operations maintain data integrity" do
      # Test that TaskServer maintains consistent state even with edge cases
      {:ok, _pid} = TaskServer.start_link()

      list_id = TaskServer.start_list()

      # Operations on valid list should work
      assert :ok = TaskServer.push_task(list_id, "task1", %{data: 1})
      assert {:ok, _task} = TaskServer.peek_task(list_id)

      # Operations on nonexistent list should be safe (return ok but no-op)
      invalid_list_id = 999
      assert :ok = TaskServer.push_task(invalid_list_id, "task", %{})
      assert {:error, :not_found} = TaskServer.peek_task(invalid_list_id)

      # Original list should be unaffected
      assert {:ok, task} = TaskServer.peek_task(list_id)
      assert task.id == "task1"
    end
  end

  describe "error message consistency" do
    test "all error messages follow consistent format" do
      # Ensure TaskServer is running for this test
      {:ok, _pid} = TaskServer.start_link()

      # Agent validation errors
      {:error, agent_error} = AI.Agent.validate_standard_opts(%{conversation: "uuid-test"})
      assert String.starts_with?(agent_error, "Missing required field:")

      # Tool argument errors  
      {:error, :missing_argument, field} = AI.Tools.CoderAgent.read_args(%{})
      assert field in ["instructions", "conversation_id"]

      # TaskServer errors follow expected format
      assert {:error, :not_found} = TaskServer.get_list(999)
      assert {:error, :empty} = TaskServer.peek_task(TaskServer.start_list())
    end

    test "error messages are user-friendly and actionable" do
      # Test that error messages don't contain internal implementation details
      {:error, error_msg} = AI.Agent.validate_standard_opts("not_a_map")

      # Should be clear and actionable
      assert error_msg == "Options must be a map"

      # Should not contain technical jargon
      refute String.contains?(error_msg, "pattern match")
      refute String.contains?(error_msg, "function clause")
      refute String.contains?(error_msg, "badarg")
    end
  end

  describe "contract specification compliance" do
    test "AI.Agent behavior defines expected callbacks" do
      # Verify the behavior contract is properly defined
      callbacks = AI.Agent.behaviour_info(:callbacks)
      assert {:get_response, 1} in callbacks

      optional_callbacks = AI.Agent.behaviour_info(:optional_callbacks)
      assert {:validate_opts, 1} in optional_callbacks
    end

    test "AI.Agent.Coder implements required behavior" do
      # Verify implementation compliance
      behaviors = AI.Agent.Coder.__info__(:attributes)[:behaviour] || []
      assert AI.Agent in behaviors

      # Verify required functions are exported
      exports = AI.Agent.Coder.__info__(:functions)
      assert {:get_response, 1} in exports
    end

    test "TaskServer enhanced validation functions work correctly" do
      {:ok, _pid} = TaskServer.start_link()

      list_id = TaskServer.start_list()

      # Test list health check
      assert {:ok, health} = TaskServer.list_health(list_id)
      assert health.total_tasks == 0
      assert health.task_counts.todo == 0

      # Add a task and check health again
      TaskServer.push_task(list_id, "test_task", %{data: 1})
      assert {:ok, health} = TaskServer.list_health(list_id)
      assert health.total_tasks == 1
      assert health.task_counts.todo == 1
      assert health.has_todo_tasks == true

      # Test integrity validation
      assert :ok = TaskServer.validate_list_integrity(list_id)

      # Test with nonexistent list
      assert {:error, :not_found} = TaskServer.list_health(999)
      assert {:error, error_msg} = TaskServer.validate_list_integrity(999)
      assert String.contains?(error_msg, "does not exist")
    end
  end
end

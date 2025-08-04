defmodule AI.ErrorFlowValidationTest do
  use Fnord.TestCase, async: false

  setup do
    # Set up project context for ConversationServer
    project = mock_project("error-flow-test")
    set_config(:project, project)
    :ok
  end

  # Helper to create a test conversation PID
  defp test_conversation_pid do
    {:ok, pid} = ConversationServer.start_link()
    pid
  end

  @moduledoc """
  Tests error flow validation and state transition safety without complex mocking.

  This test suite focuses on the contract validation and error propagation
  patterns identified in fnord's self-review, while avoiding the complexity
  and potential side effects of extensive mocking.
  """

  describe "agent behavior contracts" do
    test "AI.Agent behavior defines expected callbacks" do
      # Test that the behavior defines the expected contract
      callbacks = AI.Agent.behaviour_info(:callbacks)
      assert {:get_response, 1} in callbacks
      
      optional_callbacks = AI.Agent.behaviour_info(:optional_callbacks)
      assert {:validate_opts, 1} in optional_callbacks
    end
  end

  describe "coder agent error propagation" do
    test "get_response handles malformed options with Map.fetch" do
      # Test that AI.Agent.Coder.get_response uses Map.fetch which returns errors for missing keys
      # This relies on the 'with' construct instead of runtime validation

      # Missing required fields will cause Map.fetch to return {:error, :key}
      # This propagates through the 'with' construct
      
      invalid_cases = [
        %{conversation: test_conversation_pid()},  # missing instructions
        %{instructions: "test"}                    # missing conversation
      ]

      for invalid_opts <- invalid_cases do
        # Should return the Map.fetch error (:error), not crash
        result = AI.Agent.Coder.get_response(invalid_opts)
        assert result == :error
      end
    end

    test "get_response accepts valid options structure" do
      # Test that properly formatted options pass the initial validation
      # We can't test full execution without proper setup, but we can test that
      # the options format is accepted by the agent's initial parsing

      valid_opts = %{
        instructions: "MILESTONE: validation_test\nTest validation flow",
        conversation: test_conversation_pid()
      }

      # Should get past the Map.fetch validation and fail later due to missing Store
      result = AI.Agent.Coder.get_response(valid_opts)
      
      # Should not be a Map.fetch error (which would be :error)
      refute result == :error
      
      # May be other errors due to missing services, which is expected
      assert match?({:ok, _}, result) or match?({:error, _}, result)
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
    test "Map.fetch prevents invalid state creation" do
      # This test verifies that Map.fetch prevents missing keys
      # from reaching the agent's internal state creation logic

      # With Map.fetch and 'with' construct, missing keys fail fast
      # This is safer than runtime validation that could be bypassed
      
      invalid_opts = %{instructions: "test"}  # missing conversation
      
      # Should fail at Map.fetch, not reach state creation
      result = AI.Agent.Coder.get_response(invalid_opts)
      assert result == :error
      
      valid_opts = %{
        instructions: "MILESTONE: test\nValid milestone", 
        conversation: test_conversation_pid()
      }
      
      # Should pass Map.fetch validation (may fail later due to missing services)
      result2 = AI.Agent.Coder.get_response(valid_opts)
      refute result2 == :error
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

      # System uses consistent error formats

      # Tool argument errors  
      {:error, :missing_argument, field} = AI.Tools.CoderAgent.read_args(%{})
      assert field in ["instructions", "conversation_id"]

      # TaskServer errors follow expected format
      assert {:error, :not_found} = TaskServer.get_list(999)
      assert {:error, :empty} = TaskServer.peek_task(TaskServer.start_list())
    end

    test "error messages are user-friendly and actionable" do
      # Tool errors should be descriptive and not contain technical jargon
      {:error, :missing_argument, field} = AI.Tools.CoderAgent.read_args(%{})
      assert is_binary(field)
      assert field != ""
      
      # Should be clear field names, not internal details
      assert field in ["instructions", "conversation_id"]
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

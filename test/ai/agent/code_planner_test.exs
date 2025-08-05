defmodule AI.Agent.CodePlannerTest do
  use Fnord.TestCase

  alias AI.Agent.CodePlanner

  setup do
    :meck.new(AI.Completion, [:no_link, :passthrough, :non_strict])
    on_exit(fn -> :meck.unload(AI.Completion) end)
    {:ok, project: mock_project("test_code_planner")}
  end

  describe "get_response/1" do
    test "implements AI.Agent behavior correctly" do
      # Mock AI.Completion.get to prevent network calls
      :meck.expect(AI.Completion, :get, fn _opts ->
        {:ok, %{response: "Mocked strategic plan response"}}
      end)

      context = %{question: "Implement user authentication system"}

      result = CodePlanner.get_response(context)
      assert {:ok, "Mocked strategic plan response"} = result
    end

    test "handles missing question parameter gracefully" do
      # Mock AI.Completion.get to prevent network calls
      :meck.expect(AI.Completion, :get, fn _opts ->
        {:ok, %{response: "This should not be called"}}
      end)

      # Test that it handles missing question gracefully
      result = CodePlanner.get_response(%{})
      assert {:error, "Missing required 'question' parameter for code planning"} = result
    end

    test "handles AI completion errors gracefully" do
      # Mock AI.Completion.get to return error
      :meck.expect(AI.Completion, :get, fn _opts ->
        {:error, :api_unavailable}
      end)

      context = %{question: "Test request"}

      result = CodePlanner.get_response(context)
      assert {:error, "Planning step failed: :api_unavailable"} = result
    end

    test "handles AI completion error responses" do
      # Mock AI.Completion.get to return error response
      :meck.expect(AI.Completion, :get, fn _opts ->
        {:error, %{response: "API rate limit exceeded"}}
      end)

      context = %{question: "Test request"}

      result = CodePlanner.get_response(context)
      assert {:error, "API rate limit exceeded"} = result
    end

    test "accepts optional context parameters" do
      # Mock AI.Completion.get to prevent network calls
      :meck.expect(AI.Completion, :get, fn _opts ->
        {:ok, %{response: "Comprehensive plan with context"}}
      end)

      context = %{
        question: "Add dark mode feature",
        project: "MyApp",
        notes: "Previous research about themes",
        conversation: "User wants toggle in settings"
      }

      result = CodePlanner.get_response(context)
      assert {:ok, "Comprehensive plan with context"} = result
    end

    test "builds planning prompt correctly with context" do
      # Mock the multi-step process but focus on the first step context
      :meck.expect(AI.Completion, :get, fn opts ->
        messages = Keyword.get(opts, :messages, [])

        # Only test the first call (code analysis step)
        if length(messages) == 2 do
          system_msg = Enum.at(messages, 0)
          # Verify context is included in initial system message
          assert system_msg.content =~ "Add new API endpoints"
          assert system_msg.content =~ "**PROJECT:** TestProject"
          assert system_msg.content =~ "**RELEVANT NOTES:** API design patterns"

          assert system_msg.content =~
                   "**CONVERSATION CONTEXT:** Discussion about REST vs GraphQL"

          {:ok, %{response: "Code analysis complete"}}
        else
          {:ok, %{response: "Step complete"}}
        end
      end)

      context = %{
        question: "Add new API endpoints",
        project: "TestProject",
        notes: "API design patterns",
        conversation: "Discussion about REST vs GraphQL"
      }

      result = CodePlanner.get_response(context)
      assert {:ok, _response} = result
    end

    test "module loads and compiles correctly" do
      # Test that the module loads and compiles correctly
      assert Code.ensure_loaded?(CodePlanner)

      # Verify the module implements the AI.Agent behavior
      assert function_exported?(CodePlanner, :get_response, 1)
    end
  end

  describe "multi-step planning process" do
    test "includes all provided context in initial system message" do
      # Mock multiple AI completion calls for the multi-step process
      call_count = :counters.new(1, [])

      :meck.expect(AI.Completion, :get, fn opts ->
        :counters.add(call_count, 1, 1)
        current_call = :counters.get(call_count, 1)

        messages = Keyword.get(opts, :messages, [])

        case current_call do
          1 ->
            # First call should include initial context
            system_msg = Enum.at(messages, 0)
            assert system_msg.content =~ "**REQUEST:** Implement user system"
            assert system_msg.content =~ "**PROJECT:** TestApp"
            assert system_msg.content =~ "**RELEVANT NOTES:** Auth patterns"
            assert system_msg.content =~ "**CONVERSATION CONTEXT:** User requirements"
            {:ok, %{response: "Code analysis complete"}}

          2 ->
            {:ok, %{response: "Design phase complete"}}

          3 ->
            {:ok, %{response: "Final strategic plan"}}
        end
      end)

      context = %{
        question: "Implement user system",
        project: "TestApp",
        notes: "Auth patterns",
        conversation: "User requirements"
      }

      result = CodePlanner.get_response(context)
      assert {:ok, "Final strategic plan"} = result
      # Verify 3 completions were called
      assert :counters.get(call_count, 1) == 3
    end

    test "handles empty optional context gracefully" do
      call_count = :counters.new(1, [])

      :meck.expect(AI.Completion, :get, fn opts ->
        :counters.add(call_count, 1, 1)
        current_call = :counters.get(call_count, 1)

        messages = Keyword.get(opts, :messages, [])

        case current_call do
          1 ->
            system_msg = Enum.at(messages, 0)
            assert system_msg.content =~ "**REQUEST:** Simple task"
            refute system_msg.content =~ "**PROJECT:**"
            refute system_msg.content =~ "**RELEVANT NOTES:**"
            refute system_msg.content =~ "**CONVERSATION CONTEXT:**"
            {:ok, %{response: "Code analysis complete"}}

          2 ->
            {:ok, %{response: "Design phase complete"}}

          3 ->
            {:ok, %{response: "Final strategic plan"}}
        end
      end)

      context = %{question: "Simple task"}

      result = CodePlanner.get_response(context)
      assert {:ok, "Final strategic plan"} = result
    end
  end
end

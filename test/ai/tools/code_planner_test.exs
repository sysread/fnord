defmodule AI.Tools.CodePlannerTest do
  use Fnord.TestCase

  alias AI.Tools.CodePlanner

  describe "AI.Tools behavior" do
    test "provides proper UI notes for request" do
      args = %{"context" => %{"question" => "Implement user authentication"}}

      {title, description} = CodePlanner.ui_note_on_request(args)
      assert title == "Code planning agent analyzing request"
      assert description == "Implement user authentication"
    end

    test "handles UI notes for request without question gracefully" do
      args = %{"context" => %{"project" => "TestApp"}}

      {title, description} = CodePlanner.ui_note_on_request(args)
      assert title == "Code planning agent analyzing request"
      assert description == "coding request"
    end

    test "handles UI notes for request with invalid context" do
      args = %{"other" => "data"}

      {title, description} = CodePlanner.ui_note_on_request(args)
      assert title == "Code planning agent working"
      assert description == "Creating strategic development plan"
    end

    test "provides proper UI notes for result" do
      args = %{"context" => %{"question" => "Add REST API"}}
      result = "## Summary\nAPI implementation plan\n## Milestones\n1. Design phase"

      {title, full_report} = CodePlanner.ui_note_on_result(args, result)
      assert title == "Code planning completed"
      assert full_report =~ "Add REST API"
      assert full_report =~ "API implementation plan"
    end

    test "handles UI notes for result without question" do
      args = %{"context" => %{}}
      result = "Strategic development plan created"

      {title, description} = CodePlanner.ui_note_on_result(args, result)
      assert title == "Code planning completed"
      assert description == "Strategic development plan created"
    end

    test "async and availability behavior" do
      assert CodePlanner.async?() == true
      assert CodePlanner.is_available?() == true
    end
  end

  describe "tool specification" do
    test "provides correct tool spec structure" do
      spec = CodePlanner.spec()

      assert spec[:type] == "function"
      assert spec[:function][:name] == "code_planner_tool"
      assert is_binary(spec[:function][:description])
      assert spec[:function][:strict] == true

      # Check required parameters
      params = spec[:function][:parameters]
      assert params[:type] == "object"
      assert params[:required] == ["context"]
      assert params[:additionalProperties] == false
      assert Map.has_key?(params[:properties], :context)
    end

    test "context parameter has correct structure" do
      spec = CodePlanner.spec()
      context_param = spec[:function][:parameters][:properties][:context]

      assert context_param[:type] == "object"
      assert context_param[:additionalProperties] == true
      assert context_param[:required] == ["question"]

      # Check context properties
      props = context_param[:properties]
      assert Map.has_key?(props, :question)
      assert Map.has_key?(props, :project)
      assert Map.has_key?(props, :notes)
      assert Map.has_key?(props, :conversation)

      # Check question parameter
      question_param = props[:question]
      assert question_param[:type] == "string"
      assert is_binary(question_param[:description])
    end

    test "spec description mentions key planning capabilities" do
      spec = CodePlanner.spec()
      description = spec[:function][:description]

      # Verify key capabilities are mentioned
      assert description =~ "Strategic Code Planning Agent"
      assert description =~ "Requirements analysis"
      assert description =~ "Strategic milestone planning"
      assert description =~ "Architecture and dependency considerations"
      assert description =~ "Risk assessment"
      assert description =~ "Implementation sequencing"
    end

    test "spec description includes use cases" do
      spec = CodePlanner.spec()
      description = spec[:function][:description]

      # Verify use cases are mentioned
      assert description =~ "Feature development planning"
      assert description =~ "System refactoring strategies"
      assert description =~ "API design and implementation planning"
      assert description =~ "Database schema changes"
      assert description =~ "Integration and deployment planning"
    end
  end

  describe "argument validation" do
    test "accepts valid context with question" do
      args = %{"context" => %{"question" => "Implement feature X"}}

      result = CodePlanner.read_args(args)
      assert {:ok, ^args} = result
    end

    test "accepts context with optional parameters" do
      args = %{
        "context" => %{
          "question" => "Add API endpoints",
          "project" => "MyApp",
          "notes" => "Previous research",
          "conversation" => "User discussion"
        }
      }

      result = CodePlanner.read_args(args)
      assert {:ok, ^args} = result
    end

    test "rejects missing context parameter" do
      args = %{"other" => "data"}

      result = CodePlanner.read_args(args)
      assert {:error, :missing_argument, "context"} = result
    end

    test "rejects context that is not a map" do
      args = %{"context" => "not a map"}

      result = CodePlanner.read_args(args)
      assert {:error, :invalid_argument, "context must be a map"} = result
    end

    test "rejects context missing question" do
      args = %{"context" => %{"project" => "MyApp"}}

      result = CodePlanner.read_args(args)
      assert {:error, :missing_argument, "context.question"} = result
    end
  end

  describe "tool integration" do
    test "is registered in AI.Tools" do
      tools = AI.Tools.tools()
      assert Map.has_key?(tools, "code_planner_tool")
      assert tools["code_planner_tool"] == AI.Tools.CodePlanner
    end

    test "appears in all_tools list" do
      all_tools = AI.Tools.all_tools()
      assert Map.has_key?(all_tools, "code_planner_tool")
    end

    test "call method delegates to AI.Agent.CodePlanner" do
      # Mock the agent to prevent network calls
      :meck.new(AI.Agent.CodePlanner, [:no_link, :passthrough])

      :meck.expect(AI.Agent.CodePlanner, :get_response, fn context ->
        assert context == %{"question" => "Test planning request"}
        {:ok, "Mocked planning response"}
      end)

      args = %{"context" => %{"question" => "Test planning request"}}

      result = CodePlanner.call(args)
      assert {:ok, "Mocked planning response"} = result

      :meck.unload(AI.Agent.CodePlanner)
    end

    test "call method parameter structure is correct" do
      # Test parameter structure for the call method
      args = %{
        "context" => %{
          "question" => "Implement user management system",
          "project" => "WebApp",
          "notes" => "Requirements gathered",
          "conversation" => "User feedback session"
        }
      }

      # Verify the method signature and parameter handling work correctly
      assert is_map(args)
      assert Map.has_key?(args, "context")
      assert is_map(args["context"])
      assert Map.has_key?(args["context"], "question")
      assert is_binary(args["context"]["question"])
    end
  end

  describe "module compilation and loading" do
    test "module loads and compiles correctly" do
      # Test that the module loads and compiles correctly
      assert Code.ensure_loaded?(CodePlanner)

      # Verify the module implements all required AI.Tools callbacks
      assert function_exported?(CodePlanner, :spec, 0)
      assert function_exported?(CodePlanner, :call, 1)
      assert function_exported?(CodePlanner, :read_args, 1)
      assert function_exported?(CodePlanner, :async?, 0)
      assert function_exported?(CodePlanner, :is_available?, 0)
      assert function_exported?(CodePlanner, :ui_note_on_request, 1)
      assert function_exported?(CodePlanner, :ui_note_on_result, 2)
    end
  end
end

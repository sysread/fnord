defmodule AI.Tools.TroubleshooterTest do
  use Fnord.TestCase

  alias AI.Tools.Troubleshooter

  describe "AI.Tools behavior" do
    test "implements all required AI.Tools callbacks" do
      assert function_exported?(Troubleshooter, :async?, 0)
      assert function_exported?(Troubleshooter, :is_available?, 0)
      assert function_exported?(Troubleshooter, :ui_note_on_request, 1)
      assert function_exported?(Troubleshooter, :ui_note_on_result, 2)
      assert function_exported?(Troubleshooter, :read_args, 1)
      assert function_exported?(Troubleshooter, :spec, 0)
      assert function_exported?(Troubleshooter, :call, 1)
    end

    test "is always available and async" do
      assert Troubleshooter.is_available?() == true
      assert Troubleshooter.async?() == true
    end

    test "reads args correctly" do
      args = %{"problem" => "Test issue"}
      assert {:ok, ^args} = Troubleshooter.read_args(args)
    end

    test "provides proper UI notes" do
      args = %{"problem" => "Test compilation error"}
      
      {title, description} = Troubleshooter.ui_note_on_request(args)
      assert title == "Troubleshooting agent investigating issue"
      assert description == "Test compilation error"
      
      result = "Issue resolved by fixing import statement"
      {title, full_report} = Troubleshooter.ui_note_on_result(args, result)
      assert title == "Troubleshooting agent completed investigation"
      assert full_report =~ "Test compilation error"
      assert full_report =~ "Issue resolved by fixing import statement"
    end
  end

  describe "tool specification" do
    test "provides correct tool spec structure" do
      spec = Troubleshooter.spec()
      
      assert spec[:type] == "function"
      assert spec[:function][:name] == "troubleshooter_tool"
      assert is_binary(spec[:function][:description])
      
      # Check required parameters
      params = spec[:function][:parameters]
      assert params[:type] == "object"
      assert params[:required] == ["problem"]
      assert Map.has_key?(params[:properties], :problem)
      
      # Check problem parameter details
      problem_param = params[:properties][:problem]
      assert problem_param[:type] == "string"
      assert is_binary(problem_param[:description])
    end

    test "spec description mentions key troubleshooting workflow steps" do
      spec = Troubleshooter.spec()
      description = spec[:function][:description]
      
      # Verify workflow steps are mentioned
      assert description =~ "Context gathering"
      assert description =~ "Output analysis"
      assert description =~ "Source code investigation"
      assert description =~ "Fix proposal"
      assert description =~ "Retesting"
      assert description =~ "Escalation"
    end
  end

  describe "tool integration" do
    test "is registered in AI.Tools" do
      tools = AI.Tools.tools()
      assert Map.has_key?(tools, "troubleshooter_tool")
      assert tools["troubleshooter_tool"] == AI.Tools.Troubleshooter
    end

    test "appears in all_tools list" do
      all_tools = AI.Tools.all_tools()
      assert Map.has_key?(all_tools, "troubleshooter_tool")
    end

    test "call method invokes troubleshooter agent" do
      # This test will make an actual AI call, so we test the structure
      args = %{"problem" => "Test problem for integration"}
      
      # Test that call returns the expected structure
      result = Troubleshooter.call(args)
      
      case result do
        {:ok, response} ->
          assert is_binary(response)
        {:error, response} ->
          assert is_binary(response)
      end
    end
  end
end
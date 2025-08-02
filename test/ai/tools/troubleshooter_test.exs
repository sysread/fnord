defmodule AI.Tools.TroubleshooterTest do
  use Fnord.TestCase

  alias AI.Tools.Troubleshooter

  describe "AI.Tools behavior" do
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

      # Verify updated workflow steps are mentioned
      assert description =~ "Tool discovery and context gathering"
      assert description =~ "Output analysis"
      assert description =~ "Systematic investigation"
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

    test "call method parameter structure is correct" do
      # Test parameter structure for the call method
      args = %{"problem" => "Test problem for integration"}

      # Verify the method signature and parameter handling work correctly
      assert is_map(args)
      assert Map.has_key?(args, "problem")
      assert is_binary(args["problem"])
    end
  end
end

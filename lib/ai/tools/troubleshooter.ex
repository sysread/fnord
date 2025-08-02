defmodule AI.Tools.Troubleshooter do
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: true

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def ui_note_on_request(%{"problem" => problem}) do
    {"Troubleshooting agent investigating issue", problem}
  end

  @impl AI.Tools
  def ui_note_on_result(%{"problem" => problem}, result) do
    {"Troubleshooting agent completed investigation",
     """
     # Problem
     #{problem}

     # Investigation Results
     #{result}
     """}
  end

  @impl AI.Tools
  def read_args(args) do
    {:ok, args}
  end

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "troubleshooter_tool",
        description: """
        **AI Troubleshooting Agent for systematic problem diagnosis and resolution.**

        This agent follows a disciplined, iterative workflow to diagnose and fix any type of problem:
        1. Tool discovery and context gathering
        2. Problem reproduction using appropriate tools
        3. Output analysis and hypothesis formation  
        4. Systematic investigation (code, config, environment, etc.)
        5. Fix proposal and application
        6. Retesting and iteration
        7. Escalation with detailed findings if unable to resolve

        The troubleshooter discovers and uses all available tools including shell commands, 
        file operations, code analysis tools, and any user-created automation tools (frobs) 
        relevant to the problem domain.

        Use this for any systematic problem-solving including:
        - Build failures, compilation errors, or test failures
        - CI/CD pipeline issues and deployment problems
        - Runtime bugs, performance issues, or system problems
        - Configuration, environment, or dependency issues
        - Command-line tool failures or script errors
        - Infrastructure or service integration problems

        The agent adapts its approach based on available tools and problem type, providing 
        transparent investigation with complete documentation of all steps, tools used, 
        and reasoning applied.
        """,
        parameters: %{
          type: "object",
          required: ["problem"],
          properties: %{
            problem: %{
              type: "string",
              description: """
              A clear description of the problem to troubleshoot. Include:
              - Specific error messages or symptoms
              - Steps to reproduce the issue
              - Expected vs actual behavior
              - Any relevant context (recent changes, environment, etc.)
              - What has already been tried (if anything)

              The more detail you provide, the more effectively the troubleshooter 
              can investigate and resolve the issue.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(%{"problem" => problem}) do
    AI.Agent.Troubleshooter.get_response(%{prompt: problem})
  end
end

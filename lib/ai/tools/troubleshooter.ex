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

        This agent follows a disciplined, iterative workflow to diagnose and fix problems:
        1. Context gathering and reproduction
        2. Output analysis and hypothesis formation  
        3. Source code investigation
        4. Fix proposal and application
        5. Retesting and iteration
        6. Escalation with detailed findings if unable to resolve

        The troubleshooter has access to shell commands, file editing tools, and code analysis 
        capabilities to systematically investigate and resolve issues.

        Use this when you encounter:
        - Test failures or compilation errors
        - Runtime bugs or unexpected behavior
        - Performance issues or system problems
        - Configuration or environment issues

        The agent will provide transparent, step-by-step investigation with clear reasoning
        and will cite all files, commands, and outputs used in the troubleshooting process.
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
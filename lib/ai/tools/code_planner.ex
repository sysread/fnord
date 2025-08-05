defmodule AI.Tools.CodePlanner do
  @moduledoc """
  Tool wrapper for the AI.Agent.CodePlanner agent.

  Provides strategic code planning capabilities to create comprehensive
  development plans with logical milestones and implementation guidance.
  """

  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: true

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def ui_note_on_request(%{"context" => %{"question" => question}}) do
    {"Code planning agent analyzing request", question}
  end

  def ui_note_on_request(%{"context" => context}) when is_map(context) do
    question = Map.get(context, "question", "coding request")
    {"Code planning agent analyzing request", question}
  end

  def ui_note_on_request(_args) do
    {"Code planning agent working", "Creating strategic development plan"}
  end

  @impl AI.Tools
  def ui_note_on_result(%{"context" => %{"question" => question}}, result) do
    {"Code planning completed",
     """
     # Request
     #{question}

     # Strategic Plan
     #{result}
     """}
  end

  def ui_note_on_result(_args, result) do
    {"Code planning completed", result}
  end

  @impl AI.Tools
  def read_args(args) do
    case Map.fetch(args, "context") do
      {:ok, context} when is_map(context) ->
        if Map.has_key?(context, "question") do
          {:ok, args}
        else
          {:error, :missing_argument, "context.question"}
        end

      {:ok, _} ->
        {:error, :invalid_argument, "context must be a map"}

      :error ->
        {:error, :missing_argument, "context"}
    end
  end

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "code_planner_tool",
        description: """
        **Strategic Code Planning Agent for development project planning.**

        This agent creates comprehensive development plans by analyzing coding requests
        and breaking them down into logical milestones with clear deliverables.

        **Key Capabilities:**
        - Requirements analysis and scope definition
        - Strategic milestone planning (2-4 major phases)
        - Architecture and dependency considerations  
        - Risk assessment and technical challenge identification
        - Implementation sequencing and strategy recommendations

        **Planning Approach:**
        - Focuses on high-level deliverables, not individual tasks
        - Considers system design, integration points, and backwards compatibility
        - Provides rationale for milestone structure and sequencing
        - Includes testing strategy and deployment considerations
        - Balances thoroughness with practical implementation constraints

        **Use Cases:**
        - Feature development planning
        - System refactoring strategies
        - API design and implementation planning
        - Database schema changes and migrations
        - Integration and deployment planning
        - Technical debt remediation strategies

        The planner creates strategic oversight for coding projects, ensuring
        proper architectural thinking before implementation begins.
        """,
        strict: true,
        parameters: %{
          additionalProperties: false,
          type: "object",
          required: ["context"],
          properties: %{
            context: %{
              type: "object",
              description: """
              Context map containing the planning request and optional additional information.
              Must include 'question' field with the coding request to plan.
              """,
              additionalProperties: true,
              required: ["question"],
              properties: %{
                question: %{
                  type: "string",
                  description: """
                  The thoroughly researched coding request with complete requirements analysis.
                  This should be a comprehensive description that includes scope, requirements,
                  constraints, and any architectural considerations discovered during research.
                  The coordinator should have already clarified ambiguities and refined the request.
                  """
                },
                project: %{
                  type: "string",
                  description: """
                  Project name and context. Should include relevant architectural information,
                  technology stack details, and any project-specific patterns or conventions
                  that will influence the implementation approach.
                  """
                },
                notes: %{
                  type: "string",
                  description: """
                  Consolidated research findings from the coordinator's investigation phase.
                  Should include relevant code patterns, existing implementations, dependency
                  analysis, and any technical discoveries that will inform strategic planning.
                  This is critical context - never empty for edit operations.
                  """
                },
                conversation: %{
                  type: "string",
                  description: """
                  Complete conversation history and context from the coordinator's research.
                  Should include user clarifications, requirements evolution, and any strategic
                  insights gathered during the research phase. Essential for understanding
                  the full scope and user intent behind the request.
                  """
                }
              }
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(%{"context" => context}) do
    AI.Agent.CodePlanner.get_response(context)
  end
end

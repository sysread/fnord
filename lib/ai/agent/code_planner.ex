defmodule AI.Agent.CodePlanner do
  @moduledoc """
  Strategic Code Planning Agent

  This agent analyzes coding requests and creates high-level development plans
  with logical milestones. It focuses on architectural decisions, breaking down
  complex requirements into manageable phases that can be executed systematically.

  The agent provides strategic oversight for coding projects, ensuring proper
  planning before implementation begins.

  The agent follows a multi-step process with separate completions:
  1. Code analysis and impact assessment
  2. Ideal implementation design  
  3. Sequential milestone planning
  """

  @behaviour AI.Agent

  defstruct [
    :question,
    :project,
    :notes,
    :conversation_history,
    :conversation,
    :steps,
    :last_response
  ]

  @type t :: %__MODULE__{
          question: binary,
          project: binary,
          notes: binary,
          conversation_history: binary,
          conversation: pid,
          steps: list(atom),
          last_response: binary | nil
        }

  @model AI.Model.reasoning(:high)

  @impl AI.Agent
  def get_response(context) do
    with {:ok, question} <- Map.fetch(context, :question) do
      project = Map.get(context, :project, "")
      notes = Map.get(context, :notes, "")
      conversation_history = Map.get(context, :conversation, "")

      state = %__MODULE__{
        question: question,
        project: project,
        notes: notes,
        conversation_history: conversation_history,
        # Will build messages manually
        conversation: nil,
        steps: [:code_analysis, :design_phase, :milestone_planning],
        last_response: nil
      }

      case perform_step(state, []) do
        %{last_response: response} when is_binary(response) ->
          {:ok, response}

        {:error, reason} ->
          {:error, reason}
      end
    else
      :error -> {:error, "Missing required 'question' parameter for code planning"}
    end
  end

  # -----------------------------------------------------------------------------
  # Step execution - each step is a separate completion
  # -----------------------------------------------------------------------------
  defp perform_step(%{steps: [:code_analysis | steps]} = state, messages) do
    UI.debug("Analyzing code and impact")

    # Build messages for code analysis step
    initial_messages =
      if messages == [] do
        [build_initial_context_msg(state)]
      else
        messages
      end

    step_messages = initial_messages ++ [build_code_analysis_msg()]

    case get_completion(step_messages) do
      {:ok, response} ->
        # Add the response to messages and continue to next step
        updated_messages = step_messages ++ [AI.Util.assistant_msg(response)]
        updated_state = %{state | steps: steps}
        perform_step(updated_state, updated_messages)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp perform_step(%{steps: [:design_phase | steps]} = state, messages) do
    UI.debug("Designing ideal implementation")

    step_messages = messages ++ [build_design_phase_msg()]

    case get_completion(step_messages) do
      {:ok, response} ->
        updated_messages = step_messages ++ [AI.Util.assistant_msg(response)]
        updated_state = %{state | steps: steps}
        perform_step(updated_state, updated_messages)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp perform_step(%{steps: [:milestone_planning | steps]} = state, messages) do
    UI.debug("Creating milestone plan")

    step_messages = messages ++ [build_milestone_planning_msg(), build_finalize_response_msg()]

    case get_completion(step_messages) do
      {:ok, response} ->
        updated_state = %{state | steps: steps, last_response: response}
        perform_step(updated_state, [])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp perform_step(%{steps: []} = state, _messages) do
    UI.debug("Planning complete")
    state
  end

  # -----------------------------------------------------------------------------
  # Message builders - return AI.Util.msg() structs
  # -----------------------------------------------------------------------------
  defp build_initial_context_msg(state) do
    context_parts = [
      "**REQUEST:** #{state.question}"
    ]

    context_parts =
      if state.project != "" do
        context_parts ++ ["**PROJECT:** #{state.project}"]
      else
        context_parts
      end

    context_parts =
      if state.notes != "" do
        context_parts ++ ["**RELEVANT NOTES:** #{state.notes}"]
      else
        context_parts
      end

    context_parts =
      if state.conversation_history != "" do
        context_parts ++ ["**CONVERSATION CONTEXT:** #{state.conversation_history}"]
      else
        context_parts
      end

    initial_context = """
    You are starting a strategic code planning process. Here is the context:

    #{Enum.join(context_parts, "\n\n")}
    """

    AI.Util.system_msg(initial_context)
  end

  @code_analysis """
  <think>
  I need to start by thoroughly analyzing the existing codebase to understand what will be affected by this request.
  I should use my available tools to examine relevant files, understand current patterns, and identify integration points.
  This analysis is critical for creating a practical, informed plan.
  </think>

  **STEP 1: Code Analysis & Impact Assessment**

  Before I can create a sensible plan, I need to examine the existing codebase thoroughly.
  Use available tools to:
  - Identify all files, modules, and components that will be affected by this change
  - Understand current architecture, patterns, and conventions in the relevant areas  
  - Map dependencies and integration points that will be impacted
  - Note any existing similar implementations that can inform the approach

  Focus on understanding the current state before proposing changes.
  """

  defp build_code_analysis_msg() do
    AI.Util.assistant_msg(@code_analysis)
  end

  @design_phase """
  <think>
  Based on my code analysis, I now need to determine what the ideal implementation will look like.
  I should consider how the new functionality should integrate with existing patterns and what the cleanest architectural approach would be.
  </think>

  **STEP 2: Ideal Implementation Design**

  Based on the code analysis, determine what the ideal end-state looks like:
  - How should the new functionality integrate with existing patterns?
  - What is the cleanest architectural approach that fits the codebase?
  - Plan for maintainability, extensibility, and consistency with project conventions
  - Consider the target architecture and how it aligns with discovered patterns

  Describe the high-level design approach that will guide the milestone planning.
  """

  defp build_design_phase_msg() do
    AI.Util.assistant_msg(@design_phase)
  end

  @milestone_planning """
  <think>
  Now I need to break this work into logical, sequential milestones that build on each other.
  Each milestone must be independently testable and should leave the system in a stable state.
  I need to include testing strategies and address any technical debt explicitly.
  </think>

  **STEP 3: Sequential Milestone Planning**

  Create 2-4 strategic milestones that build on each other:
  - Each milestone must be independently testable and deliverable
  - Design milestones so that each one provides incremental user value
  - Plan for rollback safety - each milestone should leave the system in a stable state
  - Include testing strategy for each milestone (unit, integration, manual verification)
  - Address any temporary technical debt explicitly in subsequent milestones

  Structure the final plan with the format specified in the system prompt.
  """

  defp build_milestone_planning_msg() do
    AI.Util.assistant_msg(@milestone_planning)
  end

  @finalize_response """
  Now provide the final comprehensive development plan using this format:

  ## Code Analysis Summary
  Brief overview of affected components, architectural considerations, and integration points discovered

  ## Ideal Implementation Approach  
  High-level description of the target architecture and how it fits with existing patterns

  ## Sequential Milestones
  For each milestone (building on the previous):
  **MILESTONE: milestone_id**
  - **Objective**: What gets completed and why this milestone comes at this point
  - **Deliverables**: Specific files/components to be created or modified
  - **Testing Strategy**: How to verify this milestone works correctly
  - **Dependencies**: What from previous milestones this builds on
  - **Technical Debt**: Any shortcuts taken and how they'll be resolved later

  ## Quality Assurance Plan
  - Final integration testing approach
  - User acceptance criteria  
  - Rollback procedures if needed
  - Success metrics for the complete implementation

  This is your final response - make it comprehensive and actionable.
  """

  defp build_finalize_response_msg() do
    AI.Util.assistant_msg(@finalize_response)
  end

  # -----------------------------------------------------------------------------
  # Completion handling
  # -----------------------------------------------------------------------------
  defp get_completion(messages) do
    AI.Completion.get(
      model: @model,
      toolbox: AI.Tools.all_tools(),
      log_msgs: true,
      log_tool_calls: true,
      messages: messages
    )
    |> case do
      {:ok, %{response: response}} ->
        {:ok, response}

      {:error, %{response: response}} ->
        {:error, response}

      {:error, reason} ->
        {:error, "Planning step failed: #{inspect(reason)}"}
    end
  end
end

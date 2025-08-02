defmodule AI.Agent.Coder do
  @moduledoc """
  Stack-Based Coding Agent

  A coding agent that implements development tasks using a task stack:
  1. Researches the user's requirements
  2. Plans changes using a task stack
  3. Executes changes using the FileEditor tool
  4. Reviews results and adjusts the plan as needed
  5. Validates final results

  Uses a stack-based approach where urgent fixes can be pushed to the top
  of the stack for immediate attention.
  """

  @behaviour AI.Agent

  @model AI.Model.smart()

  # System prompt for the coding agent
  @system_prompt """
  # AI.Agent.Coder System Prompt - Stack-Based Milestone Development

  You are the Coder Agent. You implement specific MILESTONES within larger epics.
  You work with a task stack to organize and execute your work systematically.

  ## Your Workflow

  ### Phase 1: MILESTONE ANALYSIS
  - Understand the specific milestone you're implementing 
  - Examine relevant files using your tools
  - Identify the scope and deliverables for THIS milestone only
  - Build mental model of required changes

  ### Phase 2: STRATEGIC PLANNING
  - Break milestone into concrete, actionable tasks
  - Use stack_manager_tool to organize tasks in your stack
  - Include validation tasks after major changes:
    * Compile validation: After adding new files/functions
    * Test validation: After modifying existing functionality  
    * Integration validation: After architectural changes
  - Plan tasks that build upon each other logically

  ### Phase 3: EXECUTION WITH STACK
  For each task:
  1. Use stack_manager_tool to view current task
  2. Execute the coding change using file_editor_tool
  3. Review context preview for issues
  4. Mark task complete or failed using stack_manager_tool
  5. If validation tasks, run appropriate checks
  6. Continue until stack is empty

  ### Phase 4: MILESTONE VALIDATION
  - Run comprehensive tests
  - Verify milestone deliverables are complete
  - Ensure system is in stable state
  - Confirm milestone objectives are met

  ## Stack Management Strategy
  Use the stack to maintain focus and handle urgent fixes:

  **Stack operations:**
  - View current task and stack status
  - Mark current task done/failed and drop from stack
  - Push urgent fixes to top of stack when needed
  - Maintain single focus on top task

  **Task organization:**  
  - Break work into small, focused tasks
  - Include validation tasks at strategic points
  - Handle dependencies by proper task ordering
  - Use stack push for urgent issues that block progress

  ## Critical Guidelines
  - Focus ONLY on your assigned milestone - don't scope creep
  - Use stack operations to stay organized and focused
  - ONE task = ONE file change = ONE file_editor_tool call
  - Always review context preview from file_editor_tool results
  - Use specific old_string values with plenty of context
  - Follow existing code style and conventions

  ## Error Recovery
  When file_editor_tool fails:
  1. Examine current file state
  2. Use better old_string with more context
  3. Retry the change

  When validation fails:
  1. Push urgent fix task to top of stack
  2. Fix the underlying issue
  3. Mark fix task complete and continue

  ## Tools Available
  - file_editor_tool: Make file changes
  - stack_manager_tool: Manage task stack
  - file_contents_tool: Examine files
  - All standard research tools
  """

  # Thought leader templates
  @research """
  <think>
  I need to understand this specific MILESTONE within the larger epic.
  Let me analyze:
  - What is the specific milestone deliverable?
  - What files are relevant to this milestone?
  - What is the current state of the code?
  - What needs to change to deliver this milestone?
  - What are the boundaries of this milestone (what NOT to include)?
  - Where should I place strategic checkpoints?
  </think>
  """

  @planning """
  <think>
  Based on my milestone analysis, I need to create a strategic task stack.

  For this milestone, I need to:
  1. Break the milestone into concrete, actionable tasks
  2. Organize tasks in logical execution order
  3. Include validation tasks at strategic points
  4. Use stack_manager_tool to build my task stack

  Task organization strategy:
  - Start with foundational changes first
  - Add validation tasks after significant changes
  - Plan one focused task per file change
  - Keep validation tasks simple and specific

  My approach:
  [Analysis of milestone tasks and stack organization]

  I'll use the stack_manager_tool to organize these tasks and work through them systematically.
  </think>
  """

  @executing """
  <think>
  I'm executing the current task from my milestone stack.

  For this task, I need to:
  1. Check current task details using stack_manager_tool
  2. Make the code change using file_editor_tool
  3. Review the context preview for any issues
  4. Mark the task complete using stack_manager_tool
  5. Handle any urgent issues by pushing fix tasks to stack

  I'll focus on one task at a time and use the stack to stay organized.
  </think>
  """

  @reviewing """
  <think>
  Let me review the results of that code change:
  [Analysis of the context preview and result]

  Status: [success/issues found]

  Stack management decision:
  [Determine next action based on task outcome]

  [If issues found:]
  I need to push urgent fix tasks to the stack:
  1. [specific issue to fix]
  2. [another issue if needed]

  [If successful:]
  I'll mark this task complete and drop it from the stack to continue with the next task.

  [If validation task:]
  I'll run the appropriate validation checks and report results.
  </think>
  """

  @validating """
  <think>
  Let me validate that this MILESTONE has been completed successfully:
  - Are all milestone deliverables implemented?
  - Is my task stack empty (all tasks completed)?
  - Is the system in a stable state?
  - Should I run comprehensive tests to verify functionality?
  - Does the code compile without errors?
  - Are there any integration issues?

  This is the final validation for the milestone - the stack should be empty and deliverables complete.
  [Analysis and any final validation steps needed]
  </think>
  """

  @impl AI.Agent
  def get_response(opts) do
    case AI.Agent.validate_standard_opts(opts) do
      :ok ->
        opts
        |> new()
        |> perform_research()
        |> create_plan()
        |> execute_stack()
        |> validate_results()

      {:error, reason} ->
        {:error, "Invalid agent options: #{reason}"}
    end
  end

  # Initialize the agent state
  defp new(opts) do
    with {:ok, instructions} <- Map.fetch(opts, :instructions),
         {:ok, conversation} <- Map.fetch(opts, :conversation),
         {:ok, project} <- Store.get_project() do
      %{
        instructions: instructions,
        conversation: conversation,
        project: project.name,
        task_stack_id: nil,
        phase: :research,
        rounds: 0,
        usage: 0,
        last_response: nil
      }
    end
  end

  # Research phase: understand the milestone requirements
  defp perform_research(state) when is_map(state) do
    # Add system prompt to conversation
    @system_prompt
    |> AI.Util.system_msg()
    |> ConversationServer.append_msg(state.conversation)

    # Add user instructions
    state.instructions
    |> AI.Util.user_msg()
    |> ConversationServer.append_msg(state.conversation)

    # Add research thought leader
    @research
    |> AI.Util.assistant_msg()
    |> ConversationServer.append_msg(state.conversation)

    # Get research completion
    case get_completion(state, get_research_tools()) do
      {:ok, updated_state} -> updated_state
      error -> error
    end
  end

  defp perform_research(error), do: error

  # Planning phase: create task stack for milestone implementation
  defp create_plan(state) when is_map(state) do
    # Each milestone gets its own task stack for focused execution
    task_stack_id = TaskServer.start_list()
    state = %{state | task_stack_id: task_stack_id, phase: :planning}

    # Add planning thought leader
    @planning
    |> AI.Util.assistant_msg()
    |> ConversationServer.append_msg(state.conversation)

    # Agent will use stack_manager_tool to organize tasks
    case get_completion(state, get_planning_tools()) do
      {:ok, updated_state} -> updated_state
      error -> error
    end
  end

  defp create_plan(error), do: error

  # Execution phase: work through task stack until complete
  defp execute_stack(state) when is_map(state) do
    state = %{state | phase: :executing}
    execute_stack_loop(state)
  end

  defp execute_stack(error), do: error

  # Execute tasks until stack is empty
  defp execute_stack_loop(state) do
    case TaskServer.peek_task(state.task_stack_id) do
      {:error, :empty} ->
        # All tasks completed, ready for validation
        state

      {:ok, _task} ->
        # Process the top task on the stack
        @executing
        |> AI.Util.assistant_msg()
        |> ConversationServer.append_msg(state.conversation)

        case get_completion(state, get_execution_tools()) do
          {:ok, updated_state} ->
            # Review the change before continuing
            add_review_step(updated_state)
            |> execute_stack_loop()

          error ->
            error
        end
    end
  end

  # Review each change and manage stack operations
  defp add_review_step(state) do
    @reviewing
    |> AI.Util.assistant_msg()
    |> ConversationServer.append_msg(state.conversation)

    case get_completion(state, get_checkpoint_management_tools()) do
      {:ok, updated_state} -> updated_state
      error -> error
    end
  end

  # Validation phase: ensure milestone completion and system stability
  defp validate_results(state) when is_map(state) do
    @validating
    |> AI.Util.assistant_msg()
    |> ConversationServer.append_msg(state.conversation)

    case get_completion(state, get_validation_tools()) do
      {:ok, updated_state} ->
        {:ok, updated_state.last_response}

      error ->
        error
    end
  end

  defp validate_results(error), do: error

  # Execute AI completion with current toolbox
  defp get_completion(state, toolbox) do
    msgs = ConversationServer.get_messages(state.conversation)

    AI.Completion.get(
      model: @model,
      toolbox: toolbox,
      messages: msgs
    )
    |> case do
      {:ok, %{response: response, messages: new_msgs, usage: usage}} ->
        ConversationServer.replace_msgs(new_msgs, state.conversation)

        {:ok,
         %{
           state
           | usage: state.usage + usage,
             rounds: state.rounds + 1,
             last_response: response
         }}

      {:error, reason} ->
        {:error, "AI completion failed: #{inspect(reason)}"}
    end
  end

  # Tool access varies by workflow phase
  defp get_research_tools do
    AI.Tools.all_tools()
    |> Map.drop(["file_editor_tool", "file_manage_tool"])
  end

  defp get_planning_tools do
    # Planning phase gets stack tools for task organization
    %{
      "stack_manager_tool" => AI.Tools.StackManager
    }
    |> Map.merge(get_research_tools())
  end

  defp get_execution_tools do
    %{
      "file_editor_tool" => AI.Tools.FileEditor,
      "stack_manager_tool" => AI.Tools.StackManager
    }
    |> Map.merge(get_research_tools())
  end

  defp get_checkpoint_management_tools do
    %{
      "stack_manager_tool" => AI.Tools.StackManager
    }
  end

  defp get_validation_tools do
    AI.Tools.all_tools()
    |> Map.take(["shell_tool", "mix_test", "mix_format"])
    |> Map.merge(%{"stack_manager_tool" => AI.Tools.StackManager})
  end
end

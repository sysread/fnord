defmodule AI.Agent.Coordinator.Epics do
  @moduledoc """
  Epic Management & Milestone Execution

  Handles the hierarchical breakdown of user requests into epics and milestones,
  then delegates milestone execution to the coder agent.
  """

  @model AI.Model.smart()

  # -----------------------------------------------------------------------------
  # Public API
  # -----------------------------------------------------------------------------
  @spec create_and_execute_epic(map) :: {:ok, binary} | {:error, binary}
  def create_and_execute_epic(state) do
    # Create milestone list and plan the breakdown
    milestone_list_id = TaskServer.start_list()

    case plan_epic(state, milestone_list_id) do
      {:ok, milestones} ->
        execute_milestones(state, milestone_list_id, milestones)

      {:error, reason} ->
        {:error, "Epic planning failed: #{reason}"}
    end
  end

  # -----------------------------------------------------------------------------
  # Epic Planning
  # -----------------------------------------------------------------------------
  defp plan_epic(state, milestone_list_id) do
    # Use AI to break down the request into logical milestones
    planning_prompt = """
    I need to break down this user request into logical development milestones:

    REQUEST: #{state.question}

    Please analyze this request and create 2-4 high-level milestones that represent major deliverables.
    Each milestone should be a significant checkpoint that could be completed independently.
    Think about this like agile epics → stories → tasks.

    For each milestone, provide:
    1. A short ID (like "design_phase", "implementation", "testing")  
    2. A clear description of what gets delivered
    3. Why this milestone is logically separate from others

    Format your response as:
    MILESTONE: milestone_id
    DESCRIPTION: What gets delivered
    RATIONALE: Why this is a separate milestone

    Focus on major deliverables, not individual tasks. The coder agent will handle task-level details.
    """

    case AI.Completion.get(
           model: @model,
           messages: [AI.Util.system_msg(planning_prompt)],
           toolbox: %{}
         ) do
      {:ok, %{response: response}} ->
        milestones = parse_milestone_response(response)
        add_milestones_to_list(milestone_list_id, milestones)
        {:ok, milestones}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_milestone_response(response) do
    response
    |> String.split("MILESTONE:")
    # Remove content before first milestone
    |> Enum.drop(1)
    |> Enum.map(&parse_single_milestone/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_single_milestone(milestone_text) do
    lines = String.split(milestone_text, "\n")

    with [id_line | rest] <- lines,
         milestone_id <- String.trim(id_line),
         description <- extract_field(rest, "DESCRIPTION:"),
         rationale <- extract_field(rest, "RATIONALE:") do
      %{
        id: milestone_id,
        description: description,
        rationale: rationale
      }
    else
      _ -> nil
    end
  end

  defp extract_field(lines, field_name) do
    lines
    |> Enum.find(&String.starts_with?(&1, field_name))
    |> case do
      nil -> ""
      line -> String.trim(String.replace_prefix(line, field_name, ""))
    end
  end

  defp add_milestones_to_list(milestone_list_id, milestones) do
    Enum.each(milestones, fn milestone ->
      TaskServer.add_task(
        milestone_list_id,
        milestone.id,
        %{
          description: milestone.description,
          rationale: milestone.rationale
        }
      )
    end)
  end

  # -----------------------------------------------------------------------------
  # Milestone Execution
  # -----------------------------------------------------------------------------
  defp execute_milestones(state, milestone_list_id, milestones) do
    results =
      Enum.map(milestones, fn milestone ->
        UI.info("Executing milestone", milestone.id)

        # Execute milestone via coder agent
        milestone_instructions = """
        MILESTONE: #{milestone.id}
        DESCRIPTION: #{milestone.description}
        RATIONALE: #{milestone.rationale}

        ORIGINAL REQUEST: #{state.question}

        You are working on this specific milestone within a larger epic.
        Focus ONLY on delivering this milestone's objectives.
        Use your task stack to organize work - break this milestone into concrete tasks.
        """

        case AI.Tools.CoderAgent.call(%{
               "instructions" => milestone_instructions,
               "conversation_id" => state.conversation
             }) do
          {:ok, result} ->
            TaskServer.complete_task(milestone_list_id, milestone.id, "Milestone completed")
            UI.info("Milestone completed", milestone.id)
            %{milestone: milestone.id, status: :completed, result: result}

          {:error, reason} ->
            TaskServer.fail_task(milestone_list_id, milestone.id, reason)
            UI.error("Milestone failed", "#{milestone.id}: #{reason}")
            %{milestone: milestone.id, status: :failed, reason: reason}
        end
      end)

    # Summarize epic results
    completed = Enum.count(results, &(&1.status == :completed))
    total = length(results)

    if completed == total do
      final_summary = summarize_epic_completion(results)
      {:ok, final_summary}
    else
      failed_milestones =
        results
        |> Enum.filter(&(&1.status == :failed))
        |> Enum.map(&"#{&1.milestone}: #{&1.reason}")
        |> Enum.join("\n")

      {:error,
       "Epic partially failed. #{completed}/#{total} milestones completed.\n\nFailed milestones:\n#{failed_milestones}"}
    end
  end

  defp summarize_epic_completion(results) do
    milestone_summaries =
      results
      |> Enum.map(fn %{milestone: id, result: result} ->
        "✅ **#{id}**: #{String.slice(result, 0, 100)}#{if String.length(result) > 100, do: "...", else: ""}"
      end)
      |> Enum.join("\n\n")

    """
    # Epic Completed Successfully! 🎉

    All milestones have been delivered:

    #{milestone_summaries}

    The development work has been completed with strategic checkpoints ensuring code quality and system stability throughout the process.
    """
  end
end

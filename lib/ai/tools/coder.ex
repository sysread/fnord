defmodule AI.Tools.Coder do
  @max_steps 4

  # ----------------------------------------------------------------------------
  # Behaviour Implementation
  # ----------------------------------------------------------------------------
  @behaviour AI.Tools

  @impl AI.Tools
  def async? do
    Settings.get_edit_mode() && Settings.get_auto_approve()
  end

  @impl AI.Tools
  def is_available? do
    Settings.get_edit_mode()
  end

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def ui_note_on_request(%{"requirements" => requirements}) do
    {"Planning implementation", requirements}
  end

  @impl AI.Tools
  def ui_note_on_result(_args, result) do
    {"Changes implemented", result}
  end

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "coder_tool",
        description: """
        AI-powered, multi-phase code change orchestration.

        This tool is for large, complex code changes that span many files.
        Use this tool for "epics", not "stories".

        Use for:
        - Architectural refactoring
        - Changes spanning multiple files or modules
        - Any ambiguous or partially-specified requirement
        - Tasks demanding robust planning and post-edit validation

        NOT for quick, precise, atomic line edits; use `file_edit_tool` for those!
        """,
        parameters: %{
          type: "object",
          required: ["requirements"],
          additionalProperties: false,
          properties: %{
            requirements: %{
              type: "string",
              description: """
              Detailed requirements for the code change:
              - Purpose of the change
              - Concrete functionality to be implemented
              - Clear acceptance criteria
              - Never use the term "refactor"; the LLM *will* misinterpret it as a license to rewrite everything
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(args) do
    with {:ok, requirements} <- AI.Tools.get_arg(args, "requirements"),
         {:ok, state} <- code_stuff(requirements) do
      {:ok, summarize_outcome(state)}
    end
  end

  # ----------------------------------------------------------------------------
  # Internal State
  # ----------------------------------------------------------------------------
  defstruct [
    :requirements,
    :steps,
    :task_list_id,
    :changes
  ]

  @type t :: %__MODULE__{
          # Requirements for the overall change
          requirements: binary,

          # Number of *implementation* steps taken
          steps: non_neg_integer,

          # ID of the task list managing this change
          task_list_id: binary,

          # Summary of changes made, one per implementation step
          changes: [binary]
        }

  defp code_stuff(requirements) do
    %__MODULE__{
      requirements: requirements,
      steps: 0,
      changes: []
    }
    |> plan()
  end

  defp plan(state) do
    AI.Agent.Code.Planner
    |> AI.Agent.new()
    |> AI.Agent.get_response(%{
      request: state.requirements
    })
    |> case do
      {:ok, task_list_id} ->
        %{state | task_list_id: task_list_id}
        |> implement()

      other ->
        other
    end
  end

  defp implement(state) do
    AI.Agent.Code.TaskImplementor
    |> AI.Agent.new()
    |> AI.Agent.get_response(%{
      task_list_id: state.task_list_id,
      requirements: state.requirements
    })
    |> case do
      {:ok, changes} ->
        %{state | steps: state.steps + 1, changes: [changes | state.changes]}
        |> validate()

      other ->
        other
    end
  end

  defp validate(%{steps: steps} = state) when steps >= @max_steps do
    {:ok, state}
  end

  defp validate(state) do
    AI.Agent.Code.TaskValidator
    |> AI.Agent.new()
    |> AI.Agent.get_response(%{
      task_list_id: state.task_list_id,
      requirements: state.requirements,
      change_summary: state.changes |> Enum.join("\n")
    })
    |> case do
      {:ok, :validated} ->
        {:ok, state}

      {:error, :issues_identified} ->
        [latest | prior] = state.changes

        latest = """
        #{latest}

        Note: Validation identified problems with this iteration.
        """

        %{state | changes: [latest | prior]}
        |> implement()

      other ->
        other
    end
  end

  defp summarize_changes(%{changes: changes}) do
    changes
    |> Enum.reverse()
    |> Enum.with_index(1)
    |> Enum.map(fn {change, idx} -> "## Step #{idx}\n#{change}" end)
    |> Enum.join("\n\n")
  end

  defp summarize_outcome(%{steps: steps} = state) when steps >= @max_steps do
    """
    # Result
    #{Services.Task.as_string(state.task_list_id, true)}

    # Change Summary
    Changes were applied in #{state.steps} implementation steps.

    #{summarize_changes(state)}

    # Outcome
    The change was not completed because it exceeded the maximum number of
    implementation steps (#{@max_steps}).

    This is likely due to overly broad or ambiguous requirements or a
    logical inconsistency in the requested change.

    The changes made here were not reverted! You must review the current
    state of the code to understand what has been done so far.

    Once you have refined the requirements, you can re-run the tool to
    continue the work.
    """
  end

  defp summarize_outcome(state) do
    """
    # Result
    #{Services.Task.as_string(state.task_list_id, true)}

    # Change Summary
    Changes were applied in #{state.steps} implementation steps.

    #{summarize_changes(state)}

    # Outcome
    All changes have been successfully implemented and validated.
    """
  end
end

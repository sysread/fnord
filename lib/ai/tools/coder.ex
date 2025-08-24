defmodule AI.Tools.Coder do
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: true

  @impl AI.Tools
  def is_available?, do: true

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
         {:ok, task_list_id} <- plan(requirements),
         {:ok, change_summary} <- implement(requirements, task_list_id),
         {:ok, :validated} <- validate(requirements, task_list_id, change_summary) do
      {:ok,
       """
       # Result
       #{Services.Task.as_string(task_list_id, true)}

       # Change Summary
       #{change_summary}

       # Outcome
       All changes have been successfully implemented and validated.
       """}
    end
  end

  defp plan(requirements) do
    AI.Agent.Code.Planner.get_response(%{
      request: requirements
    })
  end

  defp implement(requirements, task_list_id) do
    AI.Agent.Code.TaskImplementor.get_response(%{
      task_list_id: task_list_id,
      requirements: requirements
    })
  end

  defp validate(requirements, task_list_id, change_summary) do
    AI.Agent.Code.TaskValidator.get_response(%{
      task_list_id: task_list_id,
      requirements: requirements,
      change_summary: change_summary
    })
  end
end

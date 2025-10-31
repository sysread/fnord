defmodule AI.Tools.TaskValidation do
  @moduledoc """
  Explicit validation tool that wraps the heavy QA validator.

  Use this when you want to validate the set of completed tasks holistically.
  The tool will compute a change summary from the current task list.
  """

  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: false

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def read_args(args) when is_map(args), do: {:ok, args}

  @impl AI.Tools
  def ui_note_on_request(%{"task_list_id" => id}) do
    {"Validating tasks", "Task list: #{id}"}
  end

  @impl AI.Tools
  def ui_note_on_result(_args, result) do
    {"Validation complete", inspect(result)}
  end

  @impl AI.Tools
  def tool_call_failure_message(_args, error) do
    {"Tool call failed", inspect(error)}
  end

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "task_validation_tool",
        description: "Run the heavy QA validator for the current set of completed tasks.",
        parameters: %{
          type: "object",
          required: ["task_list_id", "requirements"],
          additionalProperties: false,
          properties: %{
            task_list_id: %{
              type: "string",
              description: "The ID of the task list to validate."
            },
            requirements: %{
              type: "string",
              description: "The overall project requirements text that the tasks aim to satisfy."
            },
            change_summary: %{
              type: "string",
              description:
                "Optional precomputed change summary. If not provided, it will be computed from the task list.",
              default: ""
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(args) do
    with {:ok, task_list_id} <- AI.Tools.get_arg(args, "task_list_id"),
         {:ok, requirements} <- AI.Tools.get_arg(args, "requirements") do
      # Compute change summary if not provided
      change_summary =
        case Map.get(args, "change_summary") do
          s when is_binary(s) and s != "" -> s
          _ -> Services.Task.as_string(task_list_id, true)
        end

      AI.Agent.Code.TaskValidator
      |> AI.Agent.new()
      |> AI.Agent.get_response(%{
        task_list_id: task_list_id,
        requirements: requirements,
        change_summary: change_summary
      })
    end
  end
end

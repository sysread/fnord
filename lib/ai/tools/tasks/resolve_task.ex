defmodule AI.Tools.Tasks.ResolveTask do
  @moduledoc """
  Tool to resolve a task as success or failure in a Services.Task list.
  """

  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: false

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def read_args(args) when is_map(args) do
    with {:ok, list_id} <- AI.Tools.get_arg(args, "list_id"),
         true <- is_integer(list_id) or {:error, :invalid_argument, "list_id must be an integer"},
         {:ok, task_id} <- AI.Tools.get_arg(args, "task_id"),
         true <- is_binary(task_id) or {:error, :invalid_argument, "task_id must be a string"},
         task_id <- String.trim(task_id),
         true <- task_id != "" or {:error, :invalid_argument, "task_id cannot be empty"},
         {:ok, disposition} <- AI.Tools.get_arg(args, "disposition"),
         true <-
           disposition in ["success", "failure"] or
             {:error, :invalid_argument, "disposition must be 'success' or 'failure'"},
         {:ok, result} <- AI.Tools.get_arg(args, "result"),
         true <- is_binary(result) or {:error, :invalid_argument, "result must be a string"} do
      {:ok,
       %{
         "list_id" => list_id,
         "task_id" => task_id,
         "disposition" => disposition,
         "result" => result
       }}
    end
  end

  @impl AI.Tools
  def ui_note_on_request(%{
        "list_id" => list_id,
        "task_id" => task_id,
        "disposition" => disposition
      }) do
    {total, resolved} =
      list_id
      |> Services.Task.get_list()
      |> case do
        {:error, _reason} -> []
        tasks -> tasks
      end
      |> Enum.reduce({0, 0}, fn
        %{outcome: :todo}, {t, r} -> {t + 1, r}
        _, {t, r} -> {t + 1, r + 1}
      end)
      |> then(fn {t, r} ->
        if disposition == "success" do
          {t, r + 1}
        else
          {t, r}
        end
      end)

    glyph =
      if disposition == "success" do
        "✓ "
      else
        "✗ "
      end

    {"Task resolved", Util.truncate_chars("(#{resolved}/#{total}) #{glyph} #{task_id}")}
  end

  @impl AI.Tools
  def ui_note_on_result(_args, _result), do: nil

  @impl AI.Tools
  def tool_call_failure_message(_args, _reason), do: :default

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "tasks_resolve_task",
        description: """
        Resolve a task in an existing task list as either success or failure.
        The disposition and result are visible to the user, so ensure that the
        result is clear and informative.

        Include as much detail as possible in the event of a problem. This will
        help guide the user in appropriate next steps to resolve the issue.
        """,
        parameters: %{
          type: "object",
          additionalProperties: false,
          required: ["list_id", "task_id", "disposition", "result"],
          properties: %{
            "list_id" => %{
              type: :integer,
              description: "The ID of the task list."
            },
            "task_id" => %{
              type: "string",
              description: "Identifier of the task to resolve."
            },
            "disposition" => %{
              type: "string",
              enum: ["success", "failure"],
              description: "Outcome of the task"
            },
            "result" => %{
              type: "string",
              description: "Outcome message used for either success or failure"
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(%{
        "list_id" => list_id,
        "task_id" => task_id,
        "disposition" => disp,
        "result" => result
      }) do
    case disp do
      "success" -> Services.Task.complete_task(list_id, task_id, result)
      "failure" -> Services.Task.fail_task(list_id, task_id, result)
    end

    {:ok, Services.Task.as_string(list_id)}
  end
end

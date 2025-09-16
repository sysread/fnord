defmodule AI.Tools.Tasks.AddTask do
  @moduledoc """
  Tool to add a new task to a Services.Task list.
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
         {:ok, data} <- AI.Tools.get_arg(args, "data"),
         true <- is_binary(data) or {:error, :invalid_argument, "data must be a string"} do
      {:ok, %{"list_id" => list_id, "task_id" => task_id, "data" => data}}
    end
  end

  @impl AI.Tools
  def ui_note_on_request(%{"task_id" => task_id, "data" => data}) do
    {task_id, data}
  end

  @impl AI.Tools
  def ui_note_on_result(_args, result) do
    result
  end

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "tasks_add_task",
        description: """
        Add a new task to an existing task list. The task is identified by a
        unique task_id that should be a short label, describing the task at a
        glance (e.g. "Add some_function/3 to Some.Module"). The data field is a
        free-form string that can contain any details or payload for the task.

        Tasks are intended to help you retain state between interactions, even
        if your context window is full. Ensure that the data field includes
        enough context for you to understand and complete the task later, even
        if you have forgotten the details you had in mind when creating it.
        """,
        parameters: %{
          type: "object",
          additionalProperties: false,
          required: ["list_id", "task_id", "data"],
          properties: %{
            "list_id" => %{
              type: :integer,
              description: "The ID of the task list."
            },
            "task_id" => %{
              type: "string",
              description: """
              A short task label that describes the task. This doubles as the
              unique identifier for the task. Examples:
              - "Add some_function/3 to Some.Module"
              - "Write tests for Another.Module"
              - "Identify stale documentation in Some.Module"
              """
            },
            "data" => %{
              type: "string",
              description: "Free-form detail or payload for the task."
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(%{"list_id" => list_id, "task_id" => task_id, "data" => data}) do
    Services.Task.add_task(list_id, task_id, data)
    {:ok, Services.Task.as_string(list_id)}
  end
end

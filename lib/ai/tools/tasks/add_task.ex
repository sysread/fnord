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
         true <- is_integer(list_id) or {:error, :invalid_argument, "list_id must be an integer"} do
      case Map.fetch(args, "tasks") do
        {:ok, tasks} ->
          with {:ok, normalized} <- validate_and_normalize_tasks(tasks) do
            {:ok, %{"list_id" => list_id, "tasks" => normalized}}
          end

        :error ->
          with {:ok, task_id} <- AI.Tools.get_arg(args, "task_id"),
               true <-
                 is_binary(task_id) or {:error, :invalid_argument, "task_id must be a string"},
               task_id <- String.trim(task_id),
               true <- task_id != "" or {:error, :invalid_argument, "task_id cannot be empty"},
               {:ok, data} <- AI.Tools.get_arg(args, "data"),
               true <- is_binary(data) or {:error, :invalid_argument, "data must be a string"} do
            {:ok, %{"list_id" => list_id, "tasks" => [%{"task_id" => task_id, "data" => data}]}}
          end
      end
    end
  end

  @impl AI.Tools
  def ui_note_on_request(_), do: nil

  @impl AI.Tools
  def ui_note_on_result(%{"tasks" => tasks}, _result) when is_list(tasks) do
    count = length(tasks)
    "Appended #{count} task(s)"
  end

  @impl AI.Tools
  def ui_note_on_result(%{"task_id" => _task_id}, _result) do
    "Appended 1 task"
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
        name: "tasks_add_task",
        description: """
        Add a new task to an existing task list. The task is identified by a
        unique task_id that should be a short label, describing the task at a
        glance (e.g. "Add some_function/3 to Some.Module") Note that this is
        NOT a "slug" - it's a human-readable label. The data field is a
        free-form string that can contain any details or payload for the task.

        Tasks are intended to help you retain state between interactions, even
        if your context window is full. Ensure that the data field includes
        enough context for you to understand and complete the task later, even
        if you have forgotten the details you had in mind when creating it.

        Tasks are added IN ORDER - the first task in the list will be the
        next task to be completed.
        """,
        parameters: %{
          type: "object",
          additionalProperties: false,
          required: ["list_id"],
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
            },
            "tasks" => %{
              type: "array",
              description: "A list of tasks to add, each with a task_id and data.",
              items: %{
                type: "object",
                additionalProperties: false,
                required: ["task_id", "data"],
                properties: %{
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
                    description: "The detail or payload for the task."
                  }
                }
              }
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(%{"list_id" => list_id, "tasks" => tasks}) when is_list(tasks) do
    Enum.each(tasks, fn %{"task_id" => task_id, "data" => data} ->
      Services.Task.add_task(list_id, task_id, data)
    end)

    {:ok, Services.Task.as_string(list_id)}
  end

  @impl AI.Tools
  def call(%{"list_id" => list_id, "task_id" => task_id, "data" => data}) do
    Services.Task.add_task(list_id, task_id, data)
    {:ok, Services.Task.as_string(list_id)}
  end

  # Validate and normalize a list of tasks into the required format or return an error tuple.
  defp validate_and_normalize_tasks(tasks) do
    cond do
      not is_list(tasks) ->
        {:error, :invalid_argument, "tasks must be a list of task objects"}

      tasks == [] ->
        {:error, :invalid_argument, "tasks list cannot be empty"}

      true ->
        tasks
        |> Enum.reduce_while({:ok, []}, fn
          %{"task_id" => task_id, "data" => data}, {:ok, acc}
          when is_binary(task_id) and is_binary(data) ->
            task_id = String.trim(task_id)

            if task_id == "" do
              {:halt, {:error, :invalid_argument, "task_id cannot be empty"}}
            else
              {:cont, {:ok, [%{"task_id" => task_id, "data" => data} | acc]}}
            end

          %{"task_id" => _, "data" => _}, _ ->
            {:halt, {:error, :invalid_argument, "each task must have string task_id and data"}}

          _, _ ->
            {:halt,
             {:error, :invalid_argument,
              "tasks must be list of %{\"task_id\" => string, \"data\" => string}"}}
        end)
        |> case do
          {:ok, list} -> {:ok, Enum.reverse(list)}
          error -> error
        end
    end
  end
end

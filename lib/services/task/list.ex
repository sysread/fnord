defmodule Services.Task.List do
  @moduledoc """
  Represents a task list with an identifier, optional description, and a list of tasks.
  Provides core operations for creating and manipulating task lists.
  """

  defstruct id: nil, description: nil, tasks: []

  @type t :: %__MODULE__{
          id: binary,
          description: binary | nil,
          tasks: [map()]
        }

  @doc """
  Creates a new TaskList with the given `id` and optional `description`.
  """
  @spec new(binary, binary | nil) :: t
  def new(id, description \\ nil) when is_binary(id) do
    %__MODULE__{id: id, description: description, tasks: []}
  end

  @doc """
  Adds a task to the end of the task list.
  """
  @spec add(t, map()) :: t
  def add(%__MODULE__{tasks: tasks} = list, task) when is_map(task) do
    %__MODULE__{list | tasks: tasks ++ [task]}
  end

  @doc """
  Pushes a task to the front of the task list.
  """
  @spec push(t, map()) :: t
  def push(%__MODULE__{tasks: tasks} = list, task) when is_map(task) do
    %__MODULE__{list | tasks: [task | tasks]}
  end

  @doc """
  Resolves tasks with the given `task_id` by updating their `outcome` and `result`.
  Only tasks in todo state are updated.
  """
  @spec resolve(t, binary, :done | :failed, any()) :: t
  def resolve(%__MODULE__{tasks: tasks} = list, task_id, outcome, result)
      when is_binary(task_id) and outcome in [:done, :failed] do
    updated_tasks =
      Enum.map(tasks, fn
        %{id: ^task_id, outcome: :todo} = task ->
          %{task | outcome: outcome, result: result}

        other ->
          other
      end)

    %__MODULE__{list | tasks: updated_tasks}
  end

  @doc """
  Converts the task list to a string, including the header and each task.
  If `detail?` is true, includes task results for done/failed tasks.
  """
  @spec to_string(t, boolean) :: binary
  def to_string(%__MODULE__{id: id, description: desc, tasks: tasks}, detail? \\ false) do
    # Always include colon for consistency with Services.Task.as_string/2
    header =
      case desc do
        nil -> "Task List #{id}:"
        "" -> "Task List #{id}:"
        _ -> "Task List #{id}: #{desc}"
      end

    body =
      tasks
      |> Enum.map(&format_task(&1, detail?))

    Enum.join([header | body], "\n")
  end

  defp format_task(%{id: id, outcome: :todo}, _detail?),
    do: "[ ] #{id}"

  defp format_task(%{id: id, outcome: :done, result: result}, true),
    do: "[✓] #{id}: #{result}"

  defp format_task(%{id: id, outcome: :done}, false),
    do: "[✓] #{id}"

  defp format_task(%{id: id, outcome: :failed, result: result}, true),
    do: "[✗] #{id}: #{result}"

  defp format_task(%{id: id, outcome: :failed}, false),
    do: "[✗] #{id}"
end

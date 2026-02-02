defmodule AI.Tools.Tasks.CreateList do
  @moduledoc """
  Tool to create a new Services.Task list.
  """

  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: false

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def read_args(args) when is_map(args) do
    # Normalize optional params
    norm = %{}

    # Accept optional id and description parameters
    norm =
      case Map.get(args, "id") do
        s when is_binary(s) ->
          t = String.trim(s)
          if t != "", do: Map.put(norm, "id", t), else: norm

        _ ->
          norm
      end

    norm =
      case Map.get(args, "description") do
        s when is_binary(s) -> Map.put(norm, "description", s)
        _ -> norm
      end

    {:ok, norm}
  end

  @impl AI.Tools
  def ui_note_on_request(_args), do: nil

  @impl AI.Tools
  def ui_note_on_result(_args, _list_id), do: nil

  @impl AI.Tools
  def tool_call_failure_message(_args, _reason), do: :default

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "tasks_create_list",
        description: """
        Create a new task list. Returns a list_id that must be used for all
        subsequent operations on this list.

        Tasks lists are intended to help you retain state between interactions,
        even if your context window is full. You can add new tasks to the end of
        the list, push tasks to the front of the list (treating it as a stack),
        and mark tasks as completed or failed. You can also fetch the entire
        list of tasks, including their status and results.
        """,
        parameters: %{
          type: "object",
          required: [],
          properties: %{
            "id" => %{
              type: "string",
              description: "Optional custom slug for the new task list"
            },
            "description" => %{
              type: "string",
              description: "Optional description for the new task list"
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(args) when is_map(args) do
    case Map.get(args, "id") do
      id when is_binary(id) and id != "" ->
        desc = Map.get(args, "description")

        case Services.Task.start_list(%{id: id, description: desc}) do
          {:error, :exists} -> {:error, "Task list '#{id}' already exists"}
          new_id -> {:ok, Services.Task.as_string(new_id)}
        end

      _ ->
        list_id = Services.Task.start_list()

        case Map.get(args, "description") do
          desc when is_binary(desc) and desc != "" -> Services.Task.set_description(list_id, desc)
          _ -> :ok
        end

        {:ok, Services.Task.as_string(list_id)}
    end
  end
end

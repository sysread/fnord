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
  def read_args(_args), do: {:ok, %{}}

  @impl AI.Tools
  def ui_note_on_request(_args), do: nil

  @impl AI.Tools
  def ui_note_on_result(_args, _list_id), do: nil

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
          properties: %{}
        }
      }
    }
  end

  @impl AI.Tools
  def call(_args) do
    list_id = Services.Task.start_list()
    {:ok, Services.Task.as_string(list_id)}
  end
end

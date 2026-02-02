defmodule AI.Tools.Tasks.EditList do
  @moduledoc """
  Tool to update the description of an existing Services.Task list.
  """

  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: false

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def read_args(args) when is_map(args) do
    with {:ok, raw_id} <- AI.Tools.get_arg(args, "list_id"),
         {:ok, list_id} <-
           (case raw_id do
              id when is_integer(id) -> {:ok, Integer.to_string(id)}
              id when is_binary(id) -> {:ok, id}
              _ -> {:error, :invalid_argument, "list_id"}
            end),
         {:ok, description} <- AI.Tools.get_arg(args, "description"),
         true <-
           is_binary(description) or {:error, :invalid_argument, "description must be a string"} do
      {:ok, %{"list_id" => list_id, "description" => description}}
    end
  end

  @impl AI.Tools
  def ui_note_on_request(_args), do: nil

  @impl AI.Tools
  def ui_note_on_result(_args, _result), do: nil

  @impl AI.Tools
  def tool_call_failure_message(_args, _reason), do: :default

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "tasks_edit_list",
        description: "Update the description of an existing task list.",
        parameters: %{
          type: "object",
          additionalProperties: false,
          required: ["list_id", "description"],
          properties: %{
            "list_id" => %{
              type: "string",
              description: "The ID of the task list to update (string slug; integers accepted)."
            },
            "description" => %{
              type: "string",
              description: "The new description for the task list."
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(%{"list_id" => list_id, "description" => description}) do
    case Services.Task.set_description(list_id, description) do
      :ok -> {:ok, Services.Task.as_string(list_id)}
      {:error, :not_found} -> {:error, "Task list #{list_id} not found"}
    end
  end
end

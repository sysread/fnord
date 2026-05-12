defmodule AI.Tools.Tasks.ShowList do
  @moduledoc """
  Tool to return a task list as a formatted, detailed string.
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
            end) do
      {:ok, %{"list_id" => list_id}}
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
      name: "tasks_show_list",
      description: "Return the task list as a formatted string (detailed)",
      parameters: %{
        type: "object",
        additionalProperties: false,
        required: ["list_id"],
        properties: %{
          "list_id" => %{
            type: "string",
            description: "The ID of the task list (string; integers accepted)."
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(%{"list_id" => list_id}) do
    # list_id already normalized to string by read_args/1
    output = Services.Task.as_string(list_id, true)
    {:ok, output}
  end
end

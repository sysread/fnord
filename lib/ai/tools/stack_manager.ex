defmodule AI.Tools.StackManager do
  @moduledoc """
  Stack management tools for AI.Agent.Coder

  Provides tools for managing task stacks during coding operations.
  """

  @typep action :: binary
  @typep stack_id :: non_neg_integer
  @typep task_id :: binary

  @typep tool_args :: %{
           required(:action) => action,
           required(:stack_id) => stack_id,
           optional(:task_id) => task_id,
           optional(:task_data) => binary,
           optional(:result) => binary
         }

  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: false

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  @spec read_args(map) :: AI.Tools.raw_tool_result()
  def read_args(args) do
    with {:ok, action} <- AI.Tools.get_arg(args, "action"),
         {:ok, stack_id} <- AI.Tools.get_arg(args, "stack_id") do
      {:ok,
       %{
         action: action,
         stack_id: stack_id,
         task_id: Map.get(args, "task_id"),
         task_data: Map.get(args, "task_data"),
         result: Map.get(args, "result")
       }}
    end
  end

  @impl AI.Tools
  @spec ui_note_on_request(tool_args) :: {binary, binary}
  def ui_note_on_request(%{action: action, stack_id: stack_id}) do
    {"Stack Management", "#{action} on stack #{stack_id}"}
  end

  @impl AI.Tools
  @spec ui_note_on_result(tool_args, binary) :: {binary, binary}
  def ui_note_on_result(%{action: action}, result) do
    {"Stack #{action} Result", result}
  end

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "stack_manager_tool",
        description: """
        Manage the task stack for coding operations.

        Available actions:
        - push_task: Add a task to the top of the stack
        - view_stack: View current stack status
        - mark_current_done: Mark the top task as completed
        - mark_current_failed: Mark the top task as failed
        - drop_task: Remove the top task from the stack
        """,
        parameters: %{
          type: "object",
          required: ["action", "stack_id"],
          properties: %{
            action: %{
              type: "string",
              enum: [
                "push_task",
                "view_stack",
                "mark_current_done",
                "mark_current_failed",
                "drop_task"
              ],
              description: "The stack operation to perform"
            },
            stack_id: %{
              type: "number",
              description: "The ID of the task stack to operate on"
            },
            task_id: %{
              type: "string",
              description: "Task identifier (required for push_task)"
            },
            task_data: %{
              type: "string",
              description: "Task description/data (required for push_task)"
            },
            result: %{
              type: "string",
              description: "Result/reason (required for mark_current_done/failed)"
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  @spec call(tool_args) :: {:ok, binary} | {:error, binary}
  def call(%{action: "push_task"} = args), do: push_task(args)
  def call(%{action: "view_stack"} = args), do: view_stack(args)
  def call(%{action: "mark_current_done"} = args), do: mark_current_done(args)
  def call(%{action: "mark_current_failed"} = args), do: mark_current_failed(args)
  def call(%{action: "drop_task"} = args), do: drop_task(args)
  def call(%{action: action}), do: {:error, "Unknown action: #{action}"}

  defp push_task(args) do
    with {:ok, stack_id} <- AI.Tools.get_arg(args, :stack_id),
         {:ok, task_id} <- AI.Tools.get_arg(args, :task_id),
         {:ok, task_data} <- AI.Tools.get_arg(args, :task_data) do
      TaskServer.push_task(stack_id, task_id, task_data)
      {:ok, "Task '#{task_id}' pushed to top of stack #{stack_id}"}
    end
  end

  defp view_stack(args) do
    with {:ok, stack_id} <- AI.Tools.get_arg(args, :stack_id) do
      {:ok,
       """
       Current stack #{stack_id}:
       #{TaskServer.as_string(stack_id)}
       """}
    end
  end

  defp mark_current_done(args) do
    with {:ok, stack_id} <- AI.Tools.get_arg(args, :stack_id),
         {:ok, result} <- AI.Tools.get_arg(args, :result) do
      TaskServer.mark_current_done(stack_id, result)
      {:ok, "Current task marked as done: #{result}"}
    end
  end

  defp mark_current_failed(args) do
    with {:ok, stack_id} <- AI.Tools.get_arg(args, :stack_id),
         {:ok, result} <- AI.Tools.get_arg(args, :result) do
      TaskServer.mark_current_failed(stack_id, result)
      {:ok, "Current task marked as failed: #{result}"}
    end
  end

  defp drop_task(args) do
    with {:ok, stack_id} <- AI.Tools.get_arg(args, :stack_id) do
      TaskServer.drop_task(stack_id)
      {:ok, "Dropped current task from stack #{stack_id}"}
    end
  end
end

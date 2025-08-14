defmodule AI.Tools.Confirm do
  @behaviour AI.Tools

  @doc """
  This tool interacts with the user. Executing it concurrently could result in
  multiple messages appearing in the terminal together before the user has a
  chance to respond, with multiple stacked readlines waiting for input.
  Instead, we execute them synchronously, to ensure we get an answer for one
  before the next is displayed.
  """
  @impl AI.Tools
  def async?, do: false

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "confirm_tool",
        description: """
        Prompts the user for Yes/No confirmation via terminal.
        As a rule, only use this tool when the user has requested that you wait for their approval on something.
        Your code editing tools will automatically do that for the user.

        Blocks for user input if interactive.
        For automation or non-interactive runs, use the 'default' parameter.

        - message: string, required.
        - default: boolean, optional (skips user prompt in non-TTY env).

        Returns {:ok, true} for yes or {:ok, false} for no/cancel.
        """,
        parameters: %{
          type: "object",
          required: ["message"],
          properties: %{
            message: %{type: "string", description: "Prompt text shown to user"},
            default: %{type: "boolean", description: "Optional default if not interactive"}
          }
        }
      }
    }
  end

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def read_args(%{"message" => message} = args) when is_binary(message) do
    case Map.get(args, "default") do
      nil -> {:ok, %{"message" => message}}
      b when is_boolean(b) -> {:ok, %{"message" => message, "default" => b}}
      _ -> {:error, :invalid_arg, "default", "must be boolean"}
    end
  end

  def read_args(_), do: {:error, :missing_arg, "message"}

  @impl AI.Tools
  def call(%{"message" => msg} = args) do
    default = Map.get(args, "default", false)
    result = if UI.confirm(msg, default), do: true, else: false
    {:ok, result}
  end

  @impl AI.Tools
  def ui_note_on_request(%{"message" => msg}), do: {"User confirmation requested", msg}
  def ui_note_on_request(_), do: "User confirmation requested"

  @impl AI.Tools
  def ui_note_on_result(_args, {:ok, true}), do: "User confirmed: yes"
  def ui_note_on_result(_args, {:ok, false}), do: "User confirmed: no"
  def ui_note_on_result(_args, _), do: "Confirmation result processed"
end

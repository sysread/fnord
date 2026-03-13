defmodule AI.Tools.UI.Ask do
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: false

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def ui_note_on_request(%{prompt: prompt}), do: {"Asking", prompt}

  def ui_note_on_request(%{"prompt" => prompt}), do: {"Asking", prompt}

  @impl AI.Tools
  def ui_note_on_result(_args, _result), do: nil

  @impl AI.Tools
  def tool_call_failure_message(_args, reason) do
    case reason do
      :no_tty -> {"No TTY", "Cannot prompt the user (no tty or quiet mode)."}
      _ -> :default
    end
  end

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "ui_ask_tool",
        description: """
        Ask the user a question and collect a free-form text response.

        Use this when you need clarification or additional context from the user
        before proceeding.
        """,
        parameters: %{
          type: "object",
          required: ["prompt"],
          additionalProperties: false,
          properties: %{
            prompt: %{
              type: "string",
              description: "The question/prompt to show the user."
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(args) do
    with {:ok, prompt} <- AI.Tools.get_arg(args, "prompt"),
         {:ok, answer} <- prompt_user(prompt) do
      {:ok, %{answer: answer}}
    end
  end

  defp prompt_user(prompt) when is_binary(prompt) do
    case UI.prompt(prompt) do
      {:error, :no_tty} -> {:error, :no_tty}
      val -> {:ok, val}
    end
  end
end

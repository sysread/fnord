defmodule AI.Tools.UI.Confirm do
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: false

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def ui_note_on_request(%{prompt: prompt}), do: {"Confirming", prompt}

  def ui_note_on_request(%{"prompt" => prompt}), do: {"Confirming", prompt}

  @impl AI.Tools
  def ui_note_on_result(_args, _result), do: nil

  @impl AI.Tools
  def tool_call_failure_message(_args, _reason), do: :default

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "ui_confirm_tool",
        description: """
        Ask the user a yes/no question.

        Unlike UI.choose, UI.confirm works even without a tty, so this is safe
        for simpler confirmation prompts.

        Returns a structured response:
        - %{choice: :yes | :no, value: boolean}
        """,
        parameters: %{
          type: "object",
          required: ["prompt"],
          additionalProperties: false,
          properties: %{
            prompt: %{
              type: "string",
              description: "The confirmation prompt to show the user."
            },
            default: %{
              type: "boolean",
              description: "Default value used when the UI supports defaults.",
              default: false
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(args) do
    with {:ok, prompt} <- AI.Tools.get_arg(args, "prompt") do
      default = Map.get(args, "default")

      answer =
        case default do
          nil -> UI.confirm(prompt)
          v -> UI.confirm(prompt, v)
        end

      if answer do
        {:ok, %{choice: :yes, value: true}}
      else
        {:ok, %{choice: :no, value: false}}
      end
    end
  end
end

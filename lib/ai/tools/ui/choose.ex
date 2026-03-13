defmodule AI.Tools.UI.Choose do
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: false

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def ui_note_on_request(%{prompt: prompt}), do: {"Choosing", prompt}

  def ui_note_on_request(%{"prompt" => prompt}), do: {"Choosing", prompt}

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
        name: "ui_choose_tool",
        description: """
        Ask the user a multiple-choice question.

        This tool automatically adds a final choice, "Something else", which
        switches to a free-form prompt.
        """,
        parameters: %{
          type: "object",
          required: ["prompt", "options"],
          additionalProperties: false,
          properties: %{
            prompt: %{
              type: "string",
              description: "The question/prompt to show the user."
            },
            options: %{
              type: "array",
              description: "List of options to present.",
              items: %{type: "string"}
            },
            something_else_label: %{
              type: "string",
              description: "Optional label for the final free-form option.",
              default: "Something else"
            },
            something_else_prompt: %{
              type: "string",
              description: "Prompt shown when the user chooses the free-form option.",
              default: "Please specify"
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(args) do
    with {:ok, prompt} <- AI.Tools.get_arg(args, "prompt"),
         {:ok, options} <- AI.Tools.get_arg(args, "options"),
         {:ok, selection} <- choose(prompt, options, args) do
      {:ok, selection}
    end
  end

  defp choose(prompt, options, args) when is_list(options) do
    something_else_label = Map.get(args, "something_else_label") || "Something else"
    something_else_prompt = Map.get(args, "something_else_prompt") || "Please specify"

    display_options =
      options
      |> Enum.reject(&(&1 == something_else_label))
      |> Kernel.++([something_else_label])

    case UI.choose(prompt, display_options) do
      {:error, :no_tty} ->
        {:error, :no_tty}

      ^something_else_label ->
        case UI.prompt("#{something_else_prompt}:") do
          {:error, :no_tty} -> {:error, :no_tty}
          val -> {:ok, %{choice: :something_else, value: val}}
        end

      val ->
        {:ok, %{choice: :option, value: val}}
    end
  end
end

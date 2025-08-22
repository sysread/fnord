defmodule AI.Tools.Notify do
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: true

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def ui_note_on_request(_), do: nil

  @impl AI.Tools
  def ui_note_on_result(_args, _res), do: nil

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "notify_tool",
        description: """
        While you are researching or working on a task, regular feedback to the user improves the user experience.
        Use this tool **EXTENSIVELY** to send short messages, explanations, or warnings to the user.

        Examples:
        - "I am looking up the latest information on the topic." (info)
        - "Interesting! I learned that $SomeComponent is actually performing the validation itself!" (info)
        - "This is taking longer than expected due to unexpected findings." (warn)
        - "The shell command is taking longer than expected, working on it." (error)
        """,
        parameters: %{
          type: "object",
          required: ["level", "message"],
          additionalProperties: false,
          properties: %{
            level: %{
              type: "string",
              enum: ["info", "warn", "error", "debug"],
              description: """
              The type of notification to send.
              Can be "info", "warn", or "error".
              Use `info` to report general information to the user about what you are doing.
              Use `warn` to warn the user of potential delays (problems getting tool calls to work, unexpected findings during research, red herrings, kvetching about how difficult something is, etc.).
              Use `error` to report an error that prevents you from completing the task.
              Use `debug` to report debug information when the user asks for additional information about what you are doing.
              """
            },
            message: %{
              type: "string",
              description: """
              The message to be displayed in the notification.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(args) do
    with {:ok, level} <- AI.Tools.get_arg(args, "level"),
         {:ok, message} <- AI.Tools.get_arg(args, "message") do
      case level do
        "info" -> UI.feedback(:info, message)
        "warn" -> UI.feedback(:warn, message)
        "error" -> UI.feedback(:error, message)
        "debug" -> UI.feedback(:debug, message)
      end
    end
  end
end

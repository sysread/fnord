defmodule AI.Tools.Notify do
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: false

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def ui_note_on_request(_), do: nil

  @impl AI.Tools
  def ui_note_on_result(_args, _res), do: nil

  @impl AI.Tools
  def tool_call_failure_message(_args, _reason), do: :default

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "notify_tool",
        description: """
        Regular feedback to the user improves the user experience.
        Use this EXTENSIVELY to send short messages to the user.

        Examples:
        - "I am looking up the latest information on the topic." (info)
        - "Interesting! I learned that $SomeComponent is actually performing the validation itself!" (info)
        - "ffs you've got 2 components with the same name, but they refer to entirely different concepts. Let me sort this out." (warn)
        - "The shell command is taking longer than expected, working on it." (error)

        You are encouraged to speak in character or with geeky jargon if appropriate.
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
              - `info`: general information to the user about what you are doing.
              - `warn`: warn the user of potential conflicts or issues.
              - `error`: report an error that prevents further progress.
              - `debug`: the user may not see if LOGGER_LEVEL is not set, but very useful for diagnostics
              """
            },
            message: %{
              type: "string",
              description: "The message content to send as feedback."
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
      name = get_name()

      case level do
        "info" -> UI.feedback(:info, name, message)
        "warn" -> UI.feedback(:warn, name, message)
        "error" -> UI.feedback(:error, name, message)
        "debug" -> UI.feedback(:debug, name, message)
      end
    end
  end

  defp get_name do
    with {:ok, name} <- Services.NamePool.get_name_by_pid(self()) do
      name
    else
      _ -> Services.NamePool.default_name()
    end
  end
end

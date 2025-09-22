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

        You are encouraged to speak in character. Software engineers love their geekdoms!
        Memory memos:
        - If your message includes a line starting with "note to self:" or "remember:", the notes agent will capture it as a high-priority, non-transient fact in the project notes.
        - Keep memos concise and specific (one line per memo).

        Additionally, any lines in the message beginning with `note to self:` or `remember:` (case-insensitive) will be captured as memos in your project notes.
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
      # Capture memo lines and ingest asynchronously
      message
      |> extract_memo_lines()
      |> ingest_memos()

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

  @spec extract_memo_lines(String.t()) :: [String.t()]
  defp extract_memo_lines(message) do
    message
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc ->
      case Regex.run(~r/^\s*(?:note to self:|remember:)\s*(.+)$/i, line) do
        [_, memo_raw] ->
          memo = String.trim(memo_raw)

          if memo != "" do
            [memo | acc]
          else
            acc
          end

        _ ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  @spec ingest_memos([String.t()]) :: :ok
  defp ingest_memos(memos) do
    Enum.each(memos, &Services.Notes.ingest_user_msg(&1))
    :ok
  end
end

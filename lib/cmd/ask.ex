defmodule Cmd.Ask do
  @project_not_found_error "Project not found; verify that the project has been indexed."
  @default_rounds 3

  @behaviour Cmd

  @impl Cmd
  def spec() do
    [
      ask: [
        name: "ask",
        about: "Ask the AI a question about the project",
        options: [
          project: [
            value_name: "PROJECT",
            long: "--project",
            short: "-p",
            help: "Project name",
            required: true
          ],
          question: [
            value_name: "QUESTION",
            long: "--question",
            short: "-q",
            help: "The prompt to ask the AI",
            required: true
          ],
          rounds: [
            value_name: "ROUNDS",
            long: "--rounds",
            short: "-R",
            help: "The number of research rounds to perform",
            parser: :integer,
            default: @default_rounds,
            required: false
          ],
          workers: [
            value_name: "WORKERS",
            long: "--workers",
            short: "-w",
            help: "Limits the number of concurrent OpenAI requests",
            parser: :integer,
            default: Cmd.default_workers()
          ],
          follow: [
            long: "--follow",
            short: "-f",
            help: "Follow up the conversation with another question/prompt"
          ]
        ],
        flags: [
          replay: [
            long: "--replay",
            short: "-r",
            help: "Replay a conversation (with --follow is set)"
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(opts, _unknown) do
    with :ok <- validate(opts),
         {:ok, msgs, conversation} <- restore_conversation(opts),
         opts <- Map.put(opts, :msgs, msgs),
         start_time <- System.monotonic_time(:second),
         {:ok, %{msgs: msgs}} <- AI.Agent.Reason.get_response(AI.new(), opts),
         {:ok, conversation_id} <- save_conversation(conversation, msgs) do
      end_time = System.monotonic_time(:second)
      time_taken = end_time - start_time

      UI.flush()

      IO.puts("""
      -----
      - Response generated in #{time_taken} seconds
      - Conversation saved with ID #{conversation_id}
      """)
    else
      {:error, :project_not_found} -> UI.error(@project_not_found_error)
      {:ok, :testing} -> :ok
    end
  end

  defp validate(_opts) do
    Store.get_project()
    |> Store.Project.exists_in_store?()
    |> case do
      true -> :ok
      false -> {:error, :project_not_found}
    end
  end

  defp get_conversation(%{follow: conversation_id}) when is_binary(conversation_id) do
    Store.Project.Conversation.new(conversation_id)
  end

  defp get_conversation(_opts) do
    Store.Project.Conversation.new()
  end

  defp restore_conversation(opts) do
    conversation = get_conversation(opts)

    messages =
      if Store.Project.Conversation.exists?(conversation) do
        {:ok, _ts, messages} = Store.Project.Conversation.read(conversation)
        messages
      else
        []
      end

    {:ok, messages, conversation}
  end

  defp save_conversation(conversation, messages) do
    Store.Project.Conversation.write(conversation, messages)
    UI.debug("Conversation saved to file", conversation.store_path)
    UI.report_step("Conversation saved", conversation.id)
    {:ok, conversation.id}
  end
end

defmodule Cmd.Ask do
  @default_rounds 1

  @behaviour Cmd

  @impl Cmd
  def requires_project?(), do: true

  @impl Cmd
  def spec() do
    [
      ask: [
        name: "ask",
        about: "Ask the AI a question about the project",
        options: [
          project: Cmd.project_arg(),
          workers: Cmd.workers_arg(),
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
            help:
              "The number of research rounds to perform. Additional rounds generally result in more thorough research.",
            parser: :integer,
            default: @default_rounds,
            required: false
          ],
          follow: [
            value_name: "UUID",
            long: "--follow",
            short: "-f",
            help: "Continue an existing conversation by UUID",
            required: false
          ]
        ],
        flags: [
          replay: [
            long: "--replay",
            short: "-r",
            help: "Replay a conversation (with --follow)"
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(opts, _subcommands, _unknown) do
    start_time = System.monotonic_time(:second)

    with {:ok, opts} <- validate(opts),
         {:ok, msgs, conversation} <- restore_conversation(opts),
         opts <- Map.put(opts, :msgs, msgs),
         %{msgs: msgs, usage: usage, context: context} <- AI.Agent.Coordinator.get_response(opts),
         {:ok, conversation_id} <- save_conversation(conversation, msgs) do
      end_time = System.monotonic_time(:second)
      time_taken = end_time - start_time
      pct_context_used = Float.round(usage / context * 100, 2)

      UI.flush()

      usage_str = Util.format_number(usage)
      context_str = Util.format_number(context)

      {:ok, project} = Store.get_project()
      %{new: new, stale: stale, deleted: deleted} = Store.Project.index_status(project)

      UI.say("""
      ### Response Summary:
      - Response generated in #{time_taken} seconds
      - Tokens used: #{usage_str} | #{pct_context_used}% of context window (#{context_str})
      - Conversation saved with ID #{conversation_id}

      ### Project Search Index Status:
      - Stale:   #{Enum.count(stale)}
      - New:     #{Enum.count(new)}
      - Deleted: #{Enum.count(deleted)}

      _Run `fnord index` to update the index._
      """)
    else
      {:error, :invalid_rounds} ->
        UI.error("--rounds expects a positive integer")

      {:error, :conversation_not_found} ->
        UI.error("Conversation ID #{opts[:conversation]} not found")

      {:error, other} ->
        UI.error("An error occurred while generating the response:\n\n#{other}")

      {:ok, :testing} ->
        :ok
    end
  end

  defp validate(opts) do
    with :ok <- validate_conversation(opts),
         :ok <- validate_rounds(opts) do
      {:ok, opts}
    end
  end

  defp validate_rounds(%{rounds: rounds}) when rounds > 0, do: :ok
  defp validate_rounds(_opts), do: {:error, :invalid_rounds}

  defp validate_conversation(%{follow: id}) when is_binary(id) do
    id
    |> Store.Project.Conversation.new()
    |> Store.Project.Conversation.exists?()
    |> case do
      true -> :ok
      false -> {:error, :conversation_not_found}
    end
  end

  defp validate_conversation(_opts), do: :ok

  defp get_conversation(%{follow: id}) when is_binary(id) do
    {:ok, Store.Project.Conversation.new(id)}
  end

  defp get_conversation(_opts) do
    {:ok, Store.Project.Conversation.new()}
  end

  defp restore_conversation(opts) do
    with {:ok, conversation} <- get_conversation(opts) do
      messages =
        if Store.Project.Conversation.exists?(conversation) do
          {:ok, _ts, messages} = Store.Project.Conversation.read(conversation)
          messages
        else
          []
        end

      {:ok, messages, conversation}
    end
  end

  defp save_conversation(conversation, messages) do
    Store.Project.Conversation.write(conversation, messages)
    UI.debug("Conversation saved to file", conversation.store_path)
    UI.report_step("Conversation saved", conversation.id)
    {:ok, conversation.id}
  end
end

defmodule Cmd.Ask do
  @project_not_found_error "Project not found; verify that the project has been indexed."
  @template_not_found_error "Template file not found; verify that the output template file exists."
  @min_rounds 3

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
            default: @min_rounds,
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
          ],
          template: [
            value_name: "TEMPLATE",
            long: "--template",
            short: "-t",
            help: """
            The path to a file containing an output template for the AI to
            follow when generating a response. Include '$$MOTD$$' in the
            template to include the message of the day in the response.
            """
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
  def run(opts, _subcommands, _unknown) do
    ai = AI.new()
    start_time = System.monotonic_time(:second)

    with :ok <- validate(opts),
         {:ok, template} <- read_template(opts),
         {:ok, msgs, conversation} <- restore_conversation(opts),
         opts <- opts |> Map.put(:template, template) |> Map.put(:msgs, msgs),
         %{msgs: msgs} <- AI.Agent.Reason.get_response(ai, opts),
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
      {:error, :project_not_found} ->
        UI.error(@project_not_found_error)

      {:error, :template_not_found} ->
        UI.error(@template_not_found_error)

      {:error, :invalid_rounds} ->
        UI.error("Invalid number of rounds; must be greater than or equal to #{@min_rounds}")

      {:ok, :testing} ->
        :ok
    end
  end

  defp validate(opts) do
    with :ok <- validate_project(opts),
         :ok <- validate_template(opts),
         :ok <- validate_rounds(opts) do
      :ok
    end
  end

  defp validate_rounds(%{rounds: rounds}) when rounds >= @min_rounds, do: :ok
  defp validate_rounds(_opts), do: {:error, :invalid_rounds}

  defp validate_project(_opts) do
    Store.get_project()
    |> Store.Project.exists_in_store?()
    |> case do
      true -> :ok
      false -> {:error, :project_not_found}
    end
  end

  defp validate_template(%{template: nil}), do: :ok

  defp validate_template(%{template: template}) do
    if File.exists?(template) do
      :ok
    else
      {:error, :template_not_found}
    end
  end

  defp read_template(%{template: nil}), do: {:ok, nil}
  defp read_template(%{template: template}), do: File.read(template)

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

defmodule Cmd.Ask do
  @project_not_found_error "Project not found; verify that the project has been indexed."
  @template_not_found_error "Template file not found; verify that the output template file exists."
  @default_rounds 1

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
          directory: [
            value_name: "DIRECTORY",
            long: "--directory",
            short: "-d",
            help:
              "If the project has not yet been created in fnord, the project root directory is required.",
            required: false
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
            help:
              "The number of research rounds to perform. Additional rounds generally result in more thorough research.",
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

    with {:ok, opts} <- validate(opts),
         {:ok, template} <- read_template(opts),
         {:ok, msgs, conversation} <- restore_conversation(opts),
         opts <- opts |> Map.put(:template, template) |> Map.put(:msgs, msgs),
         %{msgs: msgs, usage: usage, context: context} <- AI.Agent.Reason.get_response(ai, opts),
         {:ok, conversation_id} <- save_conversation(conversation, msgs) do
      end_time = System.monotonic_time(:second)
      time_taken = end_time - start_time
      pct_context_used = Float.round(usage / context * 100, 2)

      UI.flush()

      usage_str = Util.format_number(usage)
      context_str = Util.format_number(context)

      IO.puts("""
      -----
      - Response generated in #{time_taken} seconds
      - Tokens used: #{usage_str} | #{pct_context_used}% of context window (#{context_str})
      - Conversation saved with ID #{conversation_id}
      """)
    else
      {:error, :project_not_found} ->
        UI.error(@project_not_found_error)

      {:error, :directory_not_found} ->
        UI.error("""
        The selected project has not been created in fnord and you did not provide a --directory option.
        You can either:
        - Create the project in fnord by running `fnord index --project <project> --directory <directory>`
        - Provide a valid root --directory for the project.
        """)

      {:error, :template_not_found} ->
        UI.error(@template_not_found_error)

      {:error, :invalid_rounds} ->
        UI.error("--rounds expects a positive integer")

      {:error, :conversation_not_found} ->
        UI.error("Conversation ID #{opts[:follow]} not found")

      {:ok, :testing} ->
        :ok
    end
  end

  defp validate(opts) do
    with {:ok, opts} <- validate_project(opts),
         :ok <- validate_conversation(opts),
         :ok <- validate_template(opts),
         :ok <- validate_rounds(opts) do
      {:ok, opts}
    end
  end

  defp validate_rounds(%{rounds: rounds}) when rounds > 0, do: :ok
  defp validate_rounds(_opts), do: {:error, :invalid_rounds}

  defp validate_conversation(%{follow: conversation_id}) when is_binary(conversation_id) do
    conversation_id
    |> Store.Project.Conversation.new()
    |> Store.Project.Conversation.exists?()
    |> case do
      true -> :ok
      false -> {:error, :conversation_not_found}
    end
  end

  defp validate_conversation(_opts), do: :ok

  defp validate_project(opts) do
    project = Store.get_project(opts[:project])
    exists? = Store.Project.exists_in_store?(project)
    indexed? = exists? and Store.Project.has_index?(project)
    directory = opts[:directory]

    cond do
      # Selected project is indexed - all good.
      indexed? ->
        {:ok, opts}

      # Selected project exists, but is not indexed; we can use the directory
      # from the project config.
      exists? ->
        {:ok, %{opts | directory: project.source_root}}

      # Selected project has not been created, but a directory arg was provided
      # that does exist. We can use that.
      !is_nil(directory) and File.exists?(directory) ->
        opts[:project]
        |> Store.get_project()
        |> Store.Project.save_settings(directory)
        |> Store.Project.create()
        |> Store.Project.make_default_for_session()

        {:ok, %{opts | directory: directory}}

      # Selected project has not been created, and no directory arg was provided.
      # We can't do anything.
      true ->
        {:error, :directory_not_found}
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

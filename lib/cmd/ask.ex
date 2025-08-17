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
          ],
          fork: [
            value_name: "UUID",
            long: "--fork",
            short: "-F",
            help: "Fork (branch) an existing conversation by UUID",
            required: false
          ]
        ],
        flags: [
          replay: [
            long: "--replay",
            short: "-r",
            help: "Replay a conversation (with --follow)",
            default: false
          ],
          edit: [
            long: "--edit",
            short: "-e",
            help: "Permit the AI to edit files in the project",
            default: false
          ],
          yes: [
            long: "--yes",
            short: "-y",
            help: "Automatically approve edit/manage prompts (requires --edit)",
            default: false
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(opts, _subcommands, _unknown) do
    # Start a new performance tracking session
    Services.ModelPerformanceTracker.start_session()

    opts =
      if opts[:edit] do
        UI.warning_banner("EDITING MODE ENABLED! THE AI CAN MODIFY FILES. YOU MUST BE NUTS.")
        opts
      else
        Map.put(opts, :edit, false)
      end

    # Handle --yes auto-approval flag
    if opts[:yes] do
      if opts[:edit] do
        Services.Approvals.enable_auto_approval("general", "edit files")
        Services.Approvals.enable_auto_approval("general", "file operations")
        UI.warning_banner("AUTO-CONFIRMATION ENABLED FOR CODE EDIT AND FILE-OPERATIONS PROMPTS.")
        UI.warning_banner("ALL YOU'VE *REALLY* AUTO-CONFIRMED IS THAT YOU ARE INDEED NUTS.")
      else
        UI.warn("--yes has no effect unless you also pass --edit; ignoring")
      end
    end

    start_time = System.monotonic_time(:second)

    with {:ok, opts} <- validate(opts),
         {:ok, opts} <- maybe_fork_conversation(opts),
         {:ok, pid} = Services.Conversation.start_link(opts[:follow]),
         {:ok, usage, context, response} <- get_response(opts, pid),
         {:ok, conversation_id} <- save_conversation(pid) do
      end_time = System.monotonic_time(:second)
      print_result(start_time, end_time, response, usage, context, conversation_id)
      Clipboard.copy(conversation_id)
    else
      {:error, :invalid_rounds} ->
        UI.error("--rounds expects a positive integer")

      {:error, :conversation_not_found} ->
        UI.error("Conversation ID #{opts[:conversation]} not found")

      {:error, :testing} ->
        :ok

      {:error, other} ->
        UI.error("An error occurred while generating the response:\n\n#{other}")
    end

    Services.BackupFile.offer_cleanup()
    Services.Notes.join()
    :ok
  end

  # ----------------------------------------------------------------------------
  # Validation
  # ----------------------------------------------------------------------------
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

  # -----------------------------------------------------------------------------
  # Forking a conversation
  # -----------------------------------------------------------------------------
  defp maybe_fork_conversation(%{fork: fork_id} = opts) when is_binary(fork_id) do
    fork_conv = Store.Project.Conversation.new(fork_id)

    if Store.Project.Conversation.exists?(fork_conv) do
      with {:ok, new_conv} <- Store.Project.Conversation.fork(fork_conv) do
        UI.info("Conversation #{fork_id} forked as #{new_conv.id}")
        {:ok, Map.put(opts, :follow, new_conv.id)}
      end
    else
      {:error, :conversation_not_found}
    end
  end

  defp maybe_fork_conversation(opts), do: {:ok, opts}

  # ----------------------------------------------------------------------------
  # Agent response
  # ----------------------------------------------------------------------------
  defp get_response(opts, conversation_server) do
    with {:ok, %{usage: usage, context: context, last_response: response}} <-
           AI.Agent.Coordinator.get_response_state(%{
             conversation: conversation_server,
             edit: opts.edit,
             rounds: opts.rounds,
             question: opts.question,
             replay: Map.get(opts, :replay, false)
           }) do
      {:ok, usage, context, response}
    end
  end

  # ----------------------------------------------------------------------------
  # Output
  # ----------------------------------------------------------------------------
  defp print_result(start_time, end_time, response, usage, context, conversation_id) do
    time_taken = end_time - start_time

    pct_context_used =
      if usage > 0 and context > 0 do
        Float.round(usage / context * 100, 2)
      else
        0.0
      end

    usage_str = Util.format_number(usage)
    context_str = Util.format_number(context)

    {:ok, project} = Store.get_project()
    %{new: new, stale: stale, deleted: deleted} = Store.Project.index_status(project)

    UI.say("""
    #{response}

    -----

    ### Response Summary:
    - Response generated in #{time_taken} seconds
    - Tokens used: #{usage_str} | #{pct_context_used}% of context window (#{context_str})
    - Conversation saved with ID #{conversation_id} (_copied to clipboard_)

    ### Project Search Index Status:
    - Stale:   #{Enum.count(stale)}
    - New:     #{Enum.count(new)}
    - Deleted: #{Enum.count(deleted)}

    _Run `fnord index` to update the index._
    """)

    UI.flush()
  end

  defp save_conversation(pid) do
    with {:ok, conversation} <- Services.Conversation.save(pid) do
      UI.debug("Conversation saved to file", conversation.store_path)
      UI.report_step("Conversation saved", conversation.id)
      {:ok, conversation.id}
    end
  end
end

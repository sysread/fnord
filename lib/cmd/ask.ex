defmodule Cmd.Ask do
  @default_rounds 1

  # Universal default: auto-deny after 180 seconds if no explicit auto flag
  @default_auto_policy {:deny, 180_000}

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
          auto_approve_after: [
            value_name: "SECONDS",
            long: "--auto-approve-after",
            short: "-A",
            help:
              "After notification, auto-APPROVE in SECONDS if no input. Default: auto-DENY after 180 seconds.",
            parser: :integer,
            required: false
          ],
          auto_deny_after: [
            value_name: "SECONDS",
            long: "--auto-deny-after",
            short: "-D",
            help:
              "After notification, auto-DENY in SECONDS if no input. Default: auto-DENY after 180 seconds.",
            parser: :integer,
            required: false
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
          worktree: [
            value_name: "WORKTREE",
            long: "--worktree",
            short: "-W",
            help: "Override project source root for this run",
            parser: :string,
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

        # They obviously already know if they are using --worktree
        unless opts[:worktree] do
          UI.warn("You can work from a git worktree with --worktree <dir>.")
        end

        opts
      else
        Map.put(opts, :edit, false)
      end

    # Handle --yes auto-approval flag
    if opts[:yes] do
      if opts[:edit] do
        UI.warning_banner("AUTO-CONFIRMATION ENABLED FOR CODE EDIT PROMPTS.")
        UI.warning_banner("ALL YOU'VE *REALLY* AUTO-CONFIRMED IS THAT YOU ARE INDEED NUTS.")
      else
        UI.warn("--yes has no effect unless you also pass --edit; ignoring")
      end
    end

    start_time = System.monotonic_time(:second)

    # Start silent background indexer. This must happen BEFORE any project root
    # override is applied, so that the indexer uses the correct root.
    indexer_pid =
      case Store.get_project() do
        {:ok, project} ->
          case Services.BackgroundIndexer.start_link(project: project) do
            {:ok, pid} -> pid
            _ -> nil
          end

        _ ->
          nil
      end

    try do
      with {:ok, opts} <- validate(opts),
           :ok <- set_auto_policy(opts),
           :ok <- set_worktree(opts),
           {:ok, opts} <- maybe_fork_conversation(opts),
           {:ok, pid} <- Services.Conversation.start_link(opts[:follow]),
           {:ok, usage, context, response} <- get_response(opts, pid),
           {:ok, conversation_id} <- save_conversation(pid) do
        end_time = System.monotonic_time(:second)
        print_result(start_time, end_time, response, usage, context, conversation_id)
        Clipboard.copy(conversation_id)

        unless UI.quiet?() do
          Notifier.notify("Fnord response ready", opts.question)
        end

        :ok
      else
        {:error, :testing} ->
          :ok

        {:error, :invalid_worktree} ->
          UI.error("--worktree must be an existing directory")
          {:error, :invalid_worktree}

        {:error, :auto_approval_mutually_exclusive} ->
          UI.error("--auto-approve-after and --auto-deny-after are mutually exclusive")
          {:error, :auto_approval_mutually_exclusive}

        {:error, :invalid_auto_approve_after} ->
          UI.error("--auto-approve-after must be a positive integer")
          {:error, :invalid_auto_approve_after}

        {:error, :invalid_auto_deny_after} ->
          UI.error("--auto-deny-after must be a positive integer")
          {:error, :invalid_auto_deny_after}

        {:error, :invalid_rounds} ->
          UI.error("--rounds expects a positive integer")
          {:error, :invalid_rounds}

        {:error, :conversation_not_found} ->
          UI.error("Conversation ID #{opts[:conversation]} not found")
          {:error, :conversation_not_found}

        {:error, other} ->
          UI.error("An error occurred while generating the response:\n\n#{other}")
          {:error, other}
      end
    after
      # stop background indexer if still running
      if is_pid(indexer_pid) and Process.alive?(indexer_pid) do
        Services.BackgroundIndexer.stop(indexer_pid)
      end

      Services.BackupFile.offer_cleanup()

      UI.spin(build_notes_spinner_label(), fn ->
        Services.Notes.join()
        {"Notes finalized", :ok}
      end)
    end
  end

  # ----------------------------------------------------------------------------
  # Validation
  # ----------------------------------------------------------------------------
  defp validate(opts) do
    with :ok <- validate_conversation(opts),
         :ok <- validate_rounds(opts),
         :ok <- validate_auto(opts),
         :ok <- validate_worktree(opts) do
      {:ok, opts}
    end
  end

  defp validate_rounds(%{rounds: rounds}) when is_integer(rounds) and rounds > 0, do: :ok
  defp validate_rounds(_opts), do: {:error, :invalid_rounds}

  # Validate mutual exclusion and positivity of auto flags
  @spec validate_auto(map) :: :ok | {:error, atom | binary}
  def validate_auto(opts) do
    case {opts[:auto_approve_after], opts[:auto_deny_after]} do
      {a, d} when not is_nil(a) and not is_nil(d) ->
        {:error, :auto_approval_mutually_exclusive}

      {a, _} when not is_nil(a) and a <= 0 ->
        {:error, :invalid_auto_approve_after}

      {_, d} when not is_nil(d) and d <= 0 ->
        {:error, :invalid_auto_deny_after}

      _ ->
        :ok
    end
  end

  @spec validate_worktree(map) :: :ok | {:error, :invalid_worktree}
  defp validate_worktree(%{worktree: dir}) when is_binary(dir) do
    path = Path.expand(dir)

    if File.dir?(path) do
      :ok
    else
      {:error, :invalid_worktree}
    end
  end

  defp validate_worktree(_), do: :ok

  @spec validate_conversation(map) :: :ok | {:error, :conversation_not_found}
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
  # Worktree setting
  # -----------------------------------------------------------------------------
  # 1) explicit override via --worktree/-W
  defp set_worktree(%{worktree: dir}) when is_binary(dir) do
    Settings.set_project_root_override(dir)
    UI.info("Project root overridden for session", dir)
  end

  # 2) no explicit override: detect a mismatched git worktree
  defp set_worktree(opts) do
    case Store.get_project() do
      {:ok, project} ->
        if opts[:project] do
          # Explicit project selected; do not prompt based on cwd/worktree
          UI.info("Skipping worktree detection due to explicit project flag")
          :ok
        else
          case ResolveProject.resolve_from_worktree() do
            {:ok, resolved_name} when resolved_name == project.name ->
              wt_root = GitCli.worktree_root()

              if wt_root && wt_root != project.source_root do
                if UI.is_tty?() do
                  msg = """
                  You are working on project "#{project.name}", which is rooted at:
                    #{project.source_root}

                  Your current directory is inside a git worktree at:
                    #{wt_root}

                  Would you like to set the project root to #{wt_root} for this run?
                  (equivalent to passing: --worktree #{wt_root})
                  """

                  if UI.confirm(msg, false) do
                    Settings.set_project_root_override(wt_root)
                    UI.info("Project root overridden for session", wt_root)
                  end
                else
                  UI.warn("""
                  Detected git worktree at #{wt_root} which differs from the configured project root:
                    #{project.source_root}

                  To operate from this worktree, re-run with:
                    fnord ask --edit --worktree #{wt_root} …
                  """)
                end
              end

              :ok

            _ ->
              # Fallback to GitCli detection when resolver cannot map the worktree
              if GitCli.is_worktree?() do
                wt_root = GitCli.worktree_root()

                if wt_root != project.source_root do
                  if UI.is_tty?() do
                    msg = """
                    You are working on project "#{project.name}", which is rooted at:
                      #{project.source_root}

                    Your current directory is inside a git worktree at:
                      #{wt_root}

                    Would you like to set the project root to #{wt_root} for this run?
                    (equivalent to passing: --worktree #{wt_root})
                    """

                    if UI.confirm(msg, false) do
                      Settings.set_project_root_override(wt_root)
                      UI.info("Project root overridden for session", wt_root)
                    end
                  else
                    UI.warn("""
                    Detected git worktree at #{wt_root} which differs from the configured project root:
                      #{project.source_root}

                    To operate from this worktree, re-run with:
                      fnord ask --edit --worktree #{wt_root} …
                    """)
                  end
                end
              end

              :ok
          end
        end

      _ ->
        :ok
    end
  end

  # -----------------------------------------------------------------------------
  # Auto-approval policy
  # -----------------------------------------------------------------------------

  def set_auto_policy(%{auto_approve_after: seconds}) when is_integer(seconds) do
    Settings.set_auto_policy({:approve, seconds * 1_000})
  end

  def set_auto_policy(%{auto_deny_after: seconds}) when is_integer(seconds) do
    Settings.set_auto_policy({:deny, seconds * 1_000})
  end

  def set_auto_policy(_opts) do
    # No explicit auto flags: apply universal default auto-deny policy
    Settings.set_auto_policy(@default_auto_policy)
  end

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
  @spec get_response(map, pid) ::
          {:ok, non_neg_integer, non_neg_integer, binary}
          | {:error, any}
  defp get_response(opts, conversation_server) do
    opts
    |> get_agent_response(conversation_server)
    |> case do
      {:ok, %{usage: usage, context: context, last_response: res}} ->
        {:ok, usage, context, res}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec get_agent_response(map, pid) :: {:ok, map} | {:error, any}
  defp get_agent_response(opts, conversation_server) do
    Services.Conversation.get_response(conversation_server,
      edit: opts.edit,
      rounds: opts.rounds,
      question: opts.question,
      replay: Map.get(opts, :replay, false),
      yes: Map.get(opts, :yes, false)
    )
  end

  # ----------------------------------------------------------------------------
  # Output
  # ----------------------------------------------------------------------------
  defp print_result(start_time, end_time, response, usage, context, conversation_id) do
    time_taken = end_time - start_time
    duration = Util.Duration.format(time_taken)

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
    - Response generated in #{duration}
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

  defp build_notes_spinner_label() do
    base = if AI.Notes.has_new_facts?(), do: "Consolidating notes...", else: "Finalizing notes..."

    if Services.Notes.pending?() do
      count = Services.Notes.pending_count()
      suffix = if count > 0, do: " (" <> Integer.to_string(count) <> " remaining)", else: ""
      base <> suffix
    else
      base
    end
  end
end

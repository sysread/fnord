defmodule Cmd.Ask do
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
              "After notification, auto-APPROVE in SECONDS if no input. SECONDS must be a positive integer. Default: auto-DENY after 180 seconds.",
            parser: :integer,
            required: false
          ],
          auto_deny_after: [
            value_name: "SECONDS",
            long: "--auto-deny-after",
            short: "-D",
            help:
              "After notification, auto-DENY in SECONDS if no input. SECONDS must be a positive integer. Default: auto-DENY after 180 seconds.",
            parser: :integer,
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
          ],
          frippery: [
            value_name: "LEVEL",
            long: "--frippery",
            short: "-V",
            help: "Set the model verbosity level (low, medium, high)",
            required: false
          ],
          reasoning: [
            value_name: "LEVEL",
            long: "--reasoning",
            short: "-R",
            help: "Set the AI's reasoning level (minimal, low, medium, high)",
            required: false
          ],
          tee: [
            value_name: "FILE",
            long: "--tee",
            short: "-t",
            help:
              "Write a clean (no ANSI) transcript to FILE. " <>
                "Prompts before overwriting an existing file (fails non-interactively).",
            parser: :string,
            required: false
          ],
          tee_force: [
            value_name: "FILE",
            long: "--TEE",
            short: "-T",
            help: "Like --tee, but truncates an existing file without prompting.",
            parser: :string,
            required: false
          ]
        ],
        flags: [
          quiet: Cmd.quiet_flag(),
          save: [
            long: "--save",
            short: "-S",
            help: """
            Saves the response to ~/fnord/outputs/<project_id>/<slug>.md
            """,
            default: false
          ],
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
            default: false,
            multiple: true
          ],
          smart: [
            long: "--smart",
            short: "-s",
            default: false,
            help: """
            Use a pricier model, trading speed and cash for improved accuracy on large, complex tasks
            """
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(opts, _subcommands, _unknown) do
    unless UI.quiet?() do
      UI.info("fnord version", Util.get_running_version())
    end

    # Start transcript tee before any output we want to capture
    maybe_start_tee(opts)

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
    if opts[:yes] == true or (is_integer(opts[:yes]) and opts[:yes] > 0) do
      if opts[:edit] do
        UI.warning_banner("AUTO-CONFIRMATION ENABLED FOR CODE EDIT PROMPTS.")
        UI.warning_banner("ALL YOU'VE *REALLY* AUTO-CONFIRMED IS THAT YOU ARE INDEED NUTS.")
        UI.warning_banner("TERMINATOR WAS A WARNING, NOT A SUGGESTION.")
      else
        UI.warn("--yes has no effect unless you also pass --edit; ignoring")
      end
    end

    # Handle --auto-approve-after warning
    unless is_nil(opts[:auto_approve_after]) do
      UI.warning_banner("APPROVALS WILL BE GRANTED AFTER #{opts[:auto_approve_after]} SECONDS.")
      UI.warning_banner("MAY YOUR FUTURE SELF FORGIVE YOU FOR THIS DECISION.")
      UI.warning_banner("...AND MAY THE ON-CALL HAVE MERCY ON YOUR SOUL.")
    end

    # Start silent background indexers. This must happen BEFORE any project
    # root override is applied, so that the indexers use the correct root.
    # MemoryIndexer and ConversationIndexer are independent: the memory
    # indexer self-scans for unprocessed session memories rather than relying
    # on the conversation indexer to feed it work.
    file_indexer_pid = start_file_indexer()
    conversation_indexer_pid = start_conversation_indexer()
    start_memory_indexer()

    start_time = System.monotonic_time(:second)

    try do
      with {:ok, opts} <- validate(opts),
           :ok <- set_auto_policy(opts),
           :ok <- set_worktree(opts),
           {:ok, opts} <- maybe_fork_conversation(opts),
           {:ok, pid} <- Services.Conversation.start_link(opts[:follow]),
           {:ok, _pid} <- Services.Task.start_link(conversation_pid: pid),
           :ok <-
             (
               Services.Globals.put_env(:fnord, :current_conversation, pid)
               :ok
             ),
           :ok <- Memory.init(),
           {:ok, worktree_path} <- prepare_conversation_worktree(opts, pid),
           {:ok, usage, context, response, edited?} <- get_response(opts, pid),
           {:ok, conversation_id} <- save_conversation(pid) do
        end_time = System.monotonic_time(:second)

        # Re-read the worktree path: it may have been created by the
        # coordinator during the session via git_worktree_tool, after
        # prepare_conversation_worktree returned nil.
        effective_worktree_path = Settings.get_project_root_override() || worktree_path

        UI.debug(
          "worktree",
          "post-ask: path=#{inspect(effective_worktree_path)} edited=#{edited?}"
        )

        maybe_auto_commit(effective_worktree_path, edited?, pid)

        # Discard empty worktrees (no edits made). The coordinator may have
        # speculatively created one even though no file changes were needed.
        # A fresh worktree can be created on the next --follow.
        effective_worktree_path = maybe_discard_empty_worktree(effective_worktree_path, pid)

        # Run worktree review (merge prompt) BEFORE printing the final
        # response so the diff + prompts don't push the response off screen.
        auto_merge? = opts[:yes] == true or (is_integer(opts[:yes]) and opts[:yes] > 0)

        worktree_status =
          maybe_worktree_review(effective_worktree_path, edited?, pid, auto_merge?)

        maybe_save_output(opts, conversation_id, response)

        copied_to_clipboard? =
          copied_to_clipboard?(Clipboard.copy(conversation_id), conversation_id)

        print_result(
          start_time,
          end_time,
          response,
          usage,
          context,
          conversation_id,
          effective_worktree_path,
          copied_to_clipboard?,
          worktree_status
        )

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

        {:error, :conversation_not_found} ->
          missing_id = opts[:fork] || opts[:follow] || opts[:conversation]
          UI.error("Conversation ID #{missing_id} not found")
          {:error, :conversation_not_found}

        {:error, {:conversation_worktree_exists, path}} ->
          UI.error("This conversation already has an associated worktree at #{path}")
          {:error, {:conversation_worktree_exists, path}}

        {:error, other} ->
          UI.error("An error occurred while generating the response:\n\n#{other}")
          {:error, other}
      end
    after
      # stop background indexers if still running; memory indexer is left to
      # run until the BEAM exits so it can complete light/deep sleep passes
      stop_file_indexer(file_indexer_pid)
      stop_conversation_indexer(conversation_indexer_pid)

      Services.BackupFile.offer_cleanup()

      UI.spin(build_notes_spinner_label(), fn ->
        Services.Notes.join()
        {"Notes finalized", :ok}
      end)

      # Flush and close the tee file last, after all other output
      UI.Tee.stop()
    end
  end

  # ----------------------------------------------------------------------------
  # Tee (transcript) setup
  # ----------------------------------------------------------------------------

  # Resolve --tee / --TEE into {path, force?}, then guard against
  # overwriting an existing file. --tee prompts interactively (fails
  # non-interactively); --TEE truncates without asking.
  defp maybe_start_tee(%{tee: path}) when is_binary(path), do: start_tee(path, false)
  defp maybe_start_tee(%{tee_force: path}) when is_binary(path), do: start_tee(path, true)
  defp maybe_start_tee(_opts), do: :ok

  defp start_tee(path, force?) do
    with :ok <- guard_existing_tee_file(path, force?) do
      case UI.Tee.start_link(path) do
        {:ok, _pid} ->
          # Use Elixir's Logger.Formatter (not Erlang's :logger_formatter)
          # with colors disabled so the tee file gets plain text. ANSI
          # codes from UI formatting are stripped by UI.Tee.write/1.
          {_mod, formatter_config} =
            Logger.Formatter.new(
              format: "[$level] $message\n",
              colors: [enabled: false]
            )

          :logger.add_handler(:tee, UI.Tee.LoggerHandler, %{
            level: :all,
            formatter: {Logger.Formatter, formatter_config}
          })

          UI.info("Tee", "Transcript will be written to #{path}")

        {:error, reason} ->
          UI.error("Failed to open tee file #{path}: #{inspect(reason)}")
      end
    end
  end

  # If the file exists and has content, either prompt (interactive) or bail
  # (non-interactive). Force mode skips this entirely.
  defp guard_existing_tee_file(path, true = _force) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > 0 ->
        UI.warn("Truncating existing tee file #{path} (#{size} bytes)")

      _ ->
        :ok
    end
  end

  defp guard_existing_tee_file(path, false) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > 0 ->
        if UI.is_tty?() do
          if UI.confirm("Tee file #{path} already exists (#{size} bytes). Overwrite?") do
            :ok
          else
            UI.info("Tee", "Skipping transcript (user declined overwrite)")
            :skip
          end
        else
          UI.error("Tee file #{path} already exists. Use --TEE / -T to overwrite.")
          :skip
        end

      _ ->
        :ok
    end
  end

  # ----------------------------------------------------------------------------
  # Validation
  # ----------------------------------------------------------------------------
  defp validate(opts) do
    with :ok <- validate_conversation(opts),
         :ok <- validate_auto(opts),
         :ok <- validate_worktree(opts) do
      {:ok, opts}
    end
  end

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

  # ----------------------------------------------------------------------------
  # Services
  # ----------------------------------------------------------------------------
  defp start_file_indexer() do
    case Services.BackgroundIndexer.start_link() do
      {:ok, pid} -> pid
      _ -> nil
    end
  end

  defp start_conversation_indexer() do
    case Services.ConversationIndexer.start_link() do
      {:ok, pid} -> pid
      _ -> nil
    end
  end

  defp start_memory_indexer() do
    case Process.whereis(Services.MemoryIndexer) do
      nil ->
        try do
          Services.MemoryIndexer.start_link([])
        rescue
          e ->
            UI.debug("ask", "MemoryIndexer start failed: #{Exception.message(e)}")
            :ok
        end

      _ ->
        :ok
    end
  end

  defp stop_file_indexer(pid) do
    if is_pid(pid) && Process.alive?(pid) do
      Services.BackgroundIndexer.stop(pid)
    end
  end

  defp stop_conversation_indexer(pid) do
    if is_pid(pid) && Process.alive?(pid) do
      Services.ConversationIndexer.stop(pid)
    end
  end

  # ----------------------------------------------------------------------------
  # Worktree setting
  # ----------------------------------------------------------------------------
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
          UI.info("Skipping worktree detection due to explicit project flag")
          :ok
        else
          if GitCli.is_worktree?() do
            wt_root = GitCli.worktree_root()

            if wt_root && wt_root != project.source_root do
              if UI.is_tty?() && UI.stdout_tty?() do
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
                WARNING: Detected git worktree at #{wt_root} which differs from the configured project root:
                  #{project.source_root}

                To operate from this worktree, re-run with:
                  fnord ask --edit --worktree #{wt_root}
                """)
              end
            end
          end

          :ok
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
        maybe_handle_forked_worktree(new_conv)
        {:ok, Map.put(opts, :follow, new_conv.id)}
      end
    else
      {:error, :conversation_not_found}
    end
  end

  defp maybe_fork_conversation(opts), do: {:ok, opts}

  @reuse_worktree "Reuse existing worktree"
  @new_worktree "Create new worktree"
  @no_worktree "No worktree"

  # When a forked conversation inherits worktree metadata from its source,
  # prompt the user about whether to reuse the original worktree, create a
  # new one, or proceed without a worktree. Stripping metadata before the
  # conversation server starts means the coordinator naturally sees the
  # correct state via worktree_context_msg/1.
  defp maybe_handle_forked_worktree(new_conv) do
    with {:ok, data} <- Store.Project.Conversation.read(new_conv),
         meta when is_map(meta) <- extract_forked_worktree_meta(data.metadata),
         true <- UI.is_tty?() do
      case UI.choose(
             "Source conversation has a worktree at #{meta.path}. What would you like to do?",
             [@reuse_worktree, @new_worktree, @no_worktree]
           ) do
        @reuse_worktree ->
          :ok

        choice when choice in [@new_worktree, @no_worktree] ->
          strip_worktree_metadata(new_conv, data)

        {:error, :no_tty} ->
          :ok
      end
    else
      _ -> :ok
    end
  end

  defp extract_forked_worktree_meta(metadata) when is_map(metadata) do
    meta =
      metadata
      |> GitCli.Worktree.normalize_worktree_meta_in_parent()
      |> Map.get(:worktree)

    case meta do
      %{path: path} when is_binary(path) -> meta
      _ -> nil
    end
  end

  defp strip_worktree_metadata(conv, data) do
    updated_metadata =
      data.metadata
      |> Map.delete(:worktree)
      |> Map.delete("worktree")

    Store.Project.Conversation.write(conv, %{
      data
      | metadata: updated_metadata
    })

    :ok
  end

  # ----------------------------------------------------------------------------
  # Agent response
  # ----------------------------------------------------------------------------
  @spec get_response(map, pid) ::
          {:ok, non_neg_integer, non_neg_integer, binary, boolean}
          | {:error, any}
  defp get_response(opts, conversation_server) do
    opts
    |> get_agent_response(conversation_server)
    |> case do
      {:ok, %{usage: usage, context: context, last_response: res} = state} ->
        {:ok, usage, context, res, Map.get(state, :editing_tools_used, false)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec get_agent_response(map, pid) :: {:ok, map} | {:error, any}
  defp get_agent_response(opts, conversation_server) do
    Services.Conversation.get_response(conversation_server,
      edit: opts.edit,
      question: opts.question,
      replay: Map.get(opts, :replay, false),
      yes: Map.get(opts, :yes, false),
      verbosity: Map.get(opts, :frippery, nil),
      fonz: Map.get(opts, :fonz, false)
    )
  end

  # ----------------------------------------------------------------------------
  # Output
  # ----------------------------------------------------------------------------
  defp print_result(
         start_time,
         end_time,
         response,
         usage,
         context,
         conversation_id,
         worktree_path,
         copied_to_clipboard?,
         worktree_status
       ) do
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

    worktree_summary = format_worktree_summary(worktree_path)

    UI.say("""
    #{response}

    -----

    ### Response Summary:
    - Response generated in #{duration}
    - Tokens used: #{usage_str} | #{pct_context_used}% of context window (#{context_str})
    - Conversation saved with ID #{conversation_id}#{clipboard_summary(copied_to_clipboard?)}#{worktree_summary}

    ### Index Status:
    - Stale:   #{Enum.count(stale)}
    - New:     #{Enum.count(new)}
    - Deleted: #{Enum.count(deleted)}
    - Memory:  #{count_memories(:session)} session; #{count_memories(:project)} project; #{count_memories(:global)} global#{format_search_stats()}
    """)

    print_worktree_status(worktree_status)

    UI.flush()
  end

  defp print_worktree_status({:merged, sha}) when is_binary(sha) do
    line =
      IO.ANSI.format(
        [:green, :bright, "✓ Worktree changes merged successfully (#{sha})", :reset],
        true
      )

    IO.puts(:stderr, "\n#{line}\n")
    UI.Tee.write(["\n", line, "\n\n"])
  end

  defp print_worktree_status({:merged, _}) do
    line =
      IO.ANSI.format(
        [:green, :bright, "✓ Worktree changes merged successfully", :reset],
        true
      )

    IO.puts(:stderr, "\n#{line}\n")
    UI.Tee.write(["\n", line, "\n\n"])
  end

  defp print_worktree_status(:unmerged) do
    line =
      IO.ANSI.format(
        [:yellow, :bright, "⚠ Worktree changes were not merged", :reset],
        true
      )

    IO.puts(:stderr, "\n#{line}\n")
    UI.Tee.write(["\n", line, "\n\n"])
  end

  defp print_worktree_status(:no_changes) do
    line =
      IO.ANSI.format(
        [:light_black, :italic, "(no file changes during this session)", :reset],
        true
      )

    IO.puts(:stderr, "\n#{line}\n")
    UI.Tee.write(["\n", line, "\n\n"])
  end

  defp copied_to_clipboard?(copied_value, conversation_id)
       when is_binary(conversation_id) do
    IO.iodata_to_binary(copied_value) == conversation_id
  rescue
    ArgumentError -> false
  end

  defp clipboard_summary(true), do: " (_copied to clipboard_)"
  defp clipboard_summary(false), do: ""

  @spec prepare_conversation_worktree(map, pid) :: {:ok, String.t() | nil} | {:error, term}
  defp prepare_conversation_worktree(opts, conversation_pid) do
    metadata = Services.Conversation.get_conversation_meta(conversation_pid)
    explicit_path = explicit_worktree_path(opts)
    stored_meta = worktree_meta(metadata)

    with {:ok, project} <- Store.get_project() do
      resolve_conversation_worktree(project, conversation_pid, explicit_path, stored_meta)
    end
  end

  @type worktree_meta :: %{
          path: String.t(),
          branch: String.t() | nil,
          base_branch: String.t() | nil
        }

  @spec resolve_conversation_worktree(
          any,
          pid,
          String.t() | nil,
          worktree_meta | nil
        ) :: {:ok, String.t() | nil} | {:error, {:conversation_worktree_exists, String.t() | nil}}
  # No explicit path and no stored metadata. Check whether a worktree exists
  # on disk at the default location for this conversation (handles the case
  # where a prior session created the worktree but metadata was lost, e.g.,
  # due to SIGTERM before conversation save).
  defp resolve_conversation_worktree(project, conversation_pid, nil, nil) do
    conv_id = Services.Conversation.get_id(conversation_pid)
    path = GitCli.Worktree.conversation_path(project.name, conv_id)

    if File.dir?(path) do
      UI.info("Adopting orphaned worktree", path)
      base = GitCli.Worktree.default_base_branch(GitCli.repo_root())
      meta = %{path: path, branch: "fnord-#{conv_id}", base_branch: base}

      with :ok <-
             Services.Conversation.upsert_conversation_meta(conversation_pid, %{worktree: meta}) do
        Settings.set_project_root_override(path)
        {:ok, path}
      end
    else
      {:ok, nil}
    end
  end

  defp resolve_conversation_worktree(_project, conversation_pid, path, nil)
       when is_binary(path) do
    meta = %{path: path, branch: nil, base_branch: nil}

    with :ok <-
           Services.Conversation.upsert_conversation_meta(conversation_pid, %{worktree: meta}) do
      Settings.set_project_root_override(path)
      {:ok, path}
    end
  end

  defp resolve_conversation_worktree(_project, _conversation_pid, path, stored_meta)
       when is_binary(path) and is_map(stored_meta) do
    Settings.set_project_root_override(stored_meta.path)
    {:error, {:conversation_worktree_exists, worktree_path(stored_meta)}}
  end

  defp resolve_conversation_worktree(project, conversation_pid, nil, stored_meta)
       when is_map(stored_meta) do
    stored_path = worktree_path(stored_meta)

    recreate_or_reuse_worktree(project, conversation_pid, stored_path, stored_meta)
  end

  @spec recreate_or_reuse_worktree(any, pid, String.t(), worktree_meta) ::
          {:ok, String.t()} | {:error, atom() | term()}
  defp recreate_or_reuse_worktree(project, conversation_pid, path, stored_meta)
       when is_binary(path) do
    case File.dir?(path) do
      true ->
        Settings.set_project_root_override(path)
        {:ok, path}

      false ->
        recreate_conversation_worktree(project, conversation_pid, stored_meta)
    end
  end

  @spec recreate_conversation_worktree(any, pid, worktree_meta) ::
          {:ok, String.t()} | {:error, atom() | term()}
  defp recreate_conversation_worktree(project, conversation_pid, stored_meta) do
    case GitCli.Worktree.recreate_conversation_worktree(
           project.name,
           Services.Conversation.get_id(conversation_pid),
           GitCli.Worktree.normalize_worktree_meta(stored_meta)
         ) do
      {:ok, meta} ->
        case Services.Conversation.upsert_conversation_meta(conversation_pid, %{worktree: meta}) do
          :ok ->
            Settings.set_project_root_override(meta.path)
            {:ok, meta.path}

          other ->
            other
        end

      other ->
        other
    end
  end

  defp explicit_worktree_path(%{worktree: path}) when is_binary(path), do: path
  defp explicit_worktree_path(_), do: nil

  # Extracts and normalizes worktree metadata from conversation metadata.
  # Conversation metadata may arrive with string keys (from JSON deserialization)
  # or atom keys (from in-memory state), so we normalize before returning.
  @spec worktree_meta(map) :: worktree_meta | nil
  defp worktree_meta(meta) when is_map(meta) do
    raw = Map.get(meta, :worktree) || Map.get(meta, "worktree")

    case raw do
      nil -> nil
      m when is_map(m) -> GitCli.Worktree.normalize_worktree_meta(m)
    end
  end

  @spec worktree_path(worktree_meta) :: String.t()
  defp worktree_path(%{path: path}) when is_binary(path), do: path

  defp format_worktree_summary(nil), do: ""
  defp format_worktree_summary(path), do: "\n- Worktree path: #{path}"

  defp count_memories(scope) do
    case Memory.list(scope) do
      {:ok, titles} -> length(titles)
      _ -> 0
    end
  end

  defp format_search_stats do
    case Memory.search_stats() do
      nil -> ""
      {count, avg_ms} -> "\n    - Recall:  #{count} searches, avg #{avg_ms} ms"
    end
  end

  defp save_conversation(pid) do
    with {:ok, conversation} <- Services.Conversation.save(pid) do
      UI.debug("Conversation saved to file", conversation.store_path)
      UI.report_step("Conversation saved", conversation.id)
      {:ok, conversation.id}
    end
  end

  defp build_notes_spinner_label() do
    base =
      if AI.Notes.has_new_facts?() do
        "Consolidating notes..."
      else
        "Finalizing notes..."
      end

    if Services.Notes.pending?() do
      count = Services.Notes.pending_count()

      suffix =
        if count > 0 do
          " (" <> Integer.to_string(count) <> " remaining)"
        else
          ""
        end

      base <> suffix
    else
      base
    end
  end

  # ----------------------------------------------------------------------------
  # Worktree auto-commit and review
  # ----------------------------------------------------------------------------

  # Automatically commits all changes in a fnord-managed worktree after the
  # coordinator finishes editing. Bypasses the approval system entirely since
  # this is infrastructure, not a tool call.
  @spec maybe_auto_commit(String.t() | nil, boolean, pid) :: :ok
  defp maybe_auto_commit(nil, _edited?, _conversation_pid), do: :ok
  defp maybe_auto_commit(_path, false, _conversation_pid), do: :ok

  defp maybe_auto_commit(path, true, _conversation_pid) do
    with {:ok, project} <- Store.get_project(),
         true <- GitCli.Worktree.fnord_managed?(project.name, path) do
      UI.debug("worktree", "Auto-committing in #{path}")

      case GitCli.Worktree.commit_all(path, "auto-commit") do
        {:ok, :ok} -> UI.info("Auto-committed changes in worktree", path)
        {:error, :nothing_to_commit} -> UI.debug("worktree", "Nothing to commit")
        {:error, reason} -> UI.warn("Auto-commit failed: #{reason}")
      end
    else
      other -> UI.debug("worktree", "Skipping auto-commit: #{inspect(other)}")
    end

    :ok
  end

  # If the worktree exists but has no commits beyond its base and no
  # uncommitted changes, delete it. The coordinator may have speculatively
  # created a worktree that turned out to be unused. Returns the (possibly
  # nilled) worktree path.
  @spec maybe_discard_empty_worktree(String.t() | nil, pid) :: String.t() | nil
  defp maybe_discard_empty_worktree(nil, _conversation_pid), do: nil

  defp maybe_discard_empty_worktree(path, conversation_pid) do
    with {:ok, project} <- Store.get_project(),
         true <- GitCli.Worktree.fnord_managed?(project.name, path),
         false <- GitCli.Worktree.has_uncommitted_changes?(path),
         meta when is_map(meta) <-
           worktree_meta(Services.Conversation.get_conversation_meta(conversation_pid)),
         repo_root = original_project_root(project.name),
         {:ok, diff} <-
           GitCli.Worktree.diff_from_fork_point(repo_root, meta.branch, meta.base_branch),
         true <- byte_size(diff) == 0 do
      UI.info("Discarding empty worktree", path)

      case GitCli.Worktree.delete(repo_root, path) do
        {:ok, _} -> :ok
        {:error, reason} -> UI.warn("Failed to delete empty worktree: #{reason}")
      end

      _ =
        case GitCli.Worktree.delete_branch(repo_root, meta.branch) do
          {:ok, _} ->
            :ok

          {:error, _} ->
            case GitCli.Worktree.force_delete_branch(repo_root, meta.branch) do
              {:ok, _} -> :ok
              _ -> :ok
            end
        end

      conv_id = Services.Conversation.get_id(conversation_pid)
      Cmd.WorktreeLifecycle.clear_worktree_from_conversation(conv_id)
      Settings.set_project_root_override(nil)
      nil
    else
      _ -> path
    end
  end

  # Offers an interactive review/merge/cleanup flow when the coordinator made
  # edits in a fnord-managed worktree and the user's cwd is outside it.
  # On validation failure, retries up to @max_merge_attempts times by invoking
  # the coordinator to fix the issues in the worktree.
  @max_merge_attempts 3

  @type worktree_status :: :no_changes | {:merged, String.t() | nil} | :unmerged

  @spec maybe_worktree_review(String.t() | nil, boolean, pid, boolean, non_neg_integer) ::
          worktree_status()
  defp maybe_worktree_review(path, edited?, pid, auto_merge?, attempt \\ 1)
  defp maybe_worktree_review(nil, _edited?, _pid, _auto?, _attempt), do: :no_changes
  defp maybe_worktree_review(_path, false, _pid, _auto?, _attempt), do: :no_changes

  defp maybe_worktree_review(path, true, conversation_pid, _auto?, attempt)
       when attempt > @max_merge_attempts do
    UI.error("Merge failed after #{@max_merge_attempts} validation attempts")
    show_worktree_hints(path, conversation_pid)
    :unmerged
  end

  defp maybe_worktree_review(path, true, conversation_pid, auto_merge?, attempt) do
    cwd = File.cwd!()

    with true <- cwd != path,
         {:ok, project} <- Store.get_project(),
         true <- GitCli.Worktree.fnord_managed?(project.name, path) do
      meta = worktree_meta(Services.Conversation.get_conversation_meta(conversation_pid))

      if meta do
        repo_root = original_project_root(project.name)

        result =
          if auto_merge? do
            GitCli.Worktree.Review.auto_merge(repo_root, meta)
          else
            GitCli.Worktree.Review.interactive_review(repo_root, meta)
          end

        conv_id = Services.Conversation.get_id(conversation_pid)

        case result do
          {:cleaned_up, sha} ->
            Cmd.WorktreeLifecycle.clear_worktree_from_conversation(conv_id)
            {:merged, sha}

          {:validation_failed, phase, summary} ->
            UI.warn("Validation failed (#{phase}, attempt #{attempt}/#{@max_merge_attempts})")
            run_validation_fix(conversation_pid, path, summary)
            maybe_auto_commit(path, true, conversation_pid)
            maybe_worktree_review(path, true, conversation_pid, auto_merge?, attempt + 1)

          :ok ->
            show_worktree_hints(path, conversation_pid)
            :unmerged
        end
      else
        :unmerged
      end
    else
      _ -> :unmerged
    end
  end

  defp show_worktree_hints(path, conversation_pid) do
    conv_id = Services.Conversation.get_id(conversation_pid)

    UI.say("""

    The worktree at `#{path}` still contains your changes.
    - Continue working: `fnord ask -f #{conv_id} -ey -q "..."`
    - Review the diff:  `fnord worktrees view -c #{conv_id}`
    - Merge later:      `fnord worktrees merge -c #{conv_id}`
    - Discard:          `fnord worktrees delete -c #{conv_id}`
    """)
  end

  # Invokes the coordinator for one completion cycle to fix validation failures.
  # Injects the failure context as a system message, then runs get_response
  # with the fix instructions as the question.
  defp run_validation_fix(conversation_pid, worktree_path, validation_output) do
    UI.begin_step("Fixing validation failures")

    """
    # Validation Failed

    The following validation output was produced when attempting to merge your
    worktree changes. Fix the issues in the worktree, then commit your changes.

    ```
    #{validation_output}
    ```

    The worktree is at: #{worktree_path}
    """
    |> AI.Util.system_msg()
    |> Services.Conversation.append_msg(conversation_pid)

    Services.Conversation.get_response(conversation_pid,
      edit: true,
      question: "Fix the validation failures shown above and commit the fixes.",
      replay: false,
      yes: true
    )
  end

  # Returns the project's actual source root from settings, bypassing any
  # session-level worktree override. Needed for merge/diff operations that must
  # target the real repository, not the worktree.
  @spec original_project_root(String.t()) :: String.t()
  defp original_project_root(project_name) do
    settings = Settings.new()

    Settings.get_project_data(settings, project_name)
    |> Map.get("root", File.cwd!())
    |> Path.expand()
  end

  # Persists the final assistant response when `--save` is enabled.
  # This is the integration point between the ask workflow and output storage,
  # so it translates storage failures into command-level errors instead of
  # letting pattern matches crash the command after the response has already
  # been generated.
  @spec maybe_save_output(map(), String.t(), String.t()) :: :ok | {:error, {:save_failed, term()}}
  defp maybe_save_output(opts, conversation_id, response) do
    case opts[:save] do
      true -> save_output(conversation_id, response)
      _ -> :ok
    end
  end

  # Saves an ask response for the current project and reports the saved
  # filename.
  @spec save_output(String.t(), String.t()) :: :ok | {:error, {:save_failed, term()}}
  defp save_output(conversation_id, response) do
    with {:ok, project} <- Store.get_project(),
         {:ok, path} <- Outputs.save(project.name, response, conversation_id: conversation_id) do
      UI.report_step("Output saved", Path.basename(path))
      :ok
    else
      {:error, reason} ->
        UI.error("Failed to save output: #{reason}")
        {:error, {:save_failed, reason}}
    end
  end
end

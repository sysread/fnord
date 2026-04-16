defmodule Cmd.Index do
  defstruct [
    :opts,
    :indexer,
    :project,
    :has_notes?
  ]

  @type t :: %__MODULE__{}

  # -----------------------------------------------------------------------------
  # Behaviour implementation
  # -----------------------------------------------------------------------------
  @behaviour Cmd

  @impl Cmd
  def requires_project?(), do: true

  @impl Cmd
  def spec do
    [
      index: [
        name: "index",
        about: "Index a project",
        options: [
          project: Cmd.project_arg(),
          directory: [
            value_name: "DIR",
            long: "--dir",
            short: "-d",
            help:
              "Directory to index (required for first index or reindex after moving the project)",
            required: false
          ],
          exclude: [
            value_name: "FILE",
            long: "--exclude",
            short: "-x",
            help:
              "Exclude a file, directory, or glob from being indexed; this is stored in the project's configuration and used on subsequent indexes",
            multiple: true
          ],
          workers: [
            value_name: "N",
            long: "--workers",
            short: "-w",
            help:
              "Number of concurrent embedding workers (default: max(cpu_count - 2, 8))",
            parser: :integer,
            required: false
          ]
        ],
        flags: [
          reindex: [
            long: "--reindex",
            short: "-r",
            help: "Reindex the project",
            default: false
          ],
          quiet: [
            long: "--quiet",
            short: "-Q",
            help: "Suppress the progress bar, instead logging files as they are indexed",
            required: false,
            default: false
          ],
          yes: [
            long: "--yes",
            short: "-y",
            help: "Assume 'yes' to all prompts",
            required: false,
            default: false
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(opts, _subcommands, _unknown) do
    case new(opts) do
      {:ok, idx} ->
        result = perform_task({:ok, idx})
        # Only prompt to prime notes when indexing finished cleanly. Priming
        # on a partial/failed run would invite the user to pile LLM work on
        # top of an index that's already inconsistent.
        if result == :ok, do: maybe_prime_notes(idx)
        maybe_halt_on_failure(result)

      {:error, :directory_required} ->
        UI.fatal("Error: -d | --directory is required")

      other ->
        other
        |> perform_task()
        |> maybe_halt_on_failure()
    end
  end

  # Escripts exit 0 unless we explicitly halt. If any indexing phase had
  # per-item failures (returned {:partial, ok, err}) or the top-level call
  # errored, exit non-zero so CI/scripts can tell.
  defp maybe_halt_on_failure({:error, _}), do: System.halt(1)
  defp maybe_halt_on_failure({:partial, _ok, _err}), do: System.halt(2)
  defp maybe_halt_on_failure(_), do: :ok

  @doc """
  Entry point for `file_reindex_tool`. Runs indexing inline and restores the
  prior `:quiet` setting on exit.
  """
  def run_as_tool_call(opts) do
    # Ensure we restore the global `:quiet` flag after indexing so that
    # UI output returns to its previous formatting mode.
    original_quiet = Services.Globals.get_env(:fnord, :quiet, false)

    try do
      if opts[:quiet] do
        Settings.set_quiet(true)
      end

      with {:ok, idx} <- new(opts) do
        idx
        |> Map.put(:has_notes?, true)
        |> then(&perform_task({:ok, &1}))
      end
    after
      # Restore previous quiet setting regardless of indexing outcome
      Settings.set_quiet(original_quiet)
    end
  end

  # -----------------------------------------------------------------------------
  # Task execution
  # -----------------------------------------------------------------------------
  def perform_task({:error, :user_cancelled}) do
    UI.warn("Indexing cancelled by user")
    {:error, :user_cancelled}
  end

  def perform_task({:ok, idx}) do
    # Honor an explicit --workers override before the pool spawns. Once
    # the pool is up, ensure_started/1 is a no-op, so the flag has no
    # effect on an already-running pool (not a concern for one-shot
    # `fnord index`; would matter if something else started the pool
    # first in the same BEAM).
    pool_opts =
      case Map.get(idx.opts, :workers) do
        n when is_integer(n) and n > 0 -> [workers: clamp_workers(n)]
        _ -> []
      end

    AI.Embeddings.Pool.ensure_started(pool_opts)
    AI.Embeddings.Migration.maybe_migrate(:index)

    UI.info("Project", idx.project.name)
    UI.info("   Root", idx.project.source_root)
    UI.info(" Source", describe_source(idx.project))

    UI.info(
      "Exclude",
      case idx.project.exclude do
        nil -> "None"
        globs -> Enum.join(globs, " | ")
      end
    )

    try do
      index_project(idx)
    rescue
      e ->
        UI.error("An error occurred during indexing", Exception.message(e))
        UI.info("Recovery", "Restarting the indexing process will pick up where it left off.")
        {:error, e}
    end
  end

  def perform_task(other) do
    other
  end

  def new(opts) do
    with {:ok, project} <- Store.get_project(),
         {:ok, root} <- confirm_root_changed?(project, opts),
         {:ok, exclude} <- confirm_exclude_changed?(project, opts, root) do
      # Determine whether to persist project root/exclude
      settings = Settings.new()
      orig_data = Settings.get_project_data(settings, project.name) || %{}
      orig_root = Map.get(orig_data, "root")
      # Persist only on first index, explicit --dir (non-empty), or when exclude changes
      user_dir_val = Map.get(opts, :directory)

      user_provided_dir? =
        case user_dir_val do
          nil -> false
          "" -> false
          _ -> true
        end

      persist? =
        user_provided_dir? or Map.has_key?(opts, :exclude) or is_nil(orig_root)

      # If the user provided a directory, use that expanded value; otherwise root
      project =
        project
        |> (fn project ->
              if persist? do
                Store.Project.save_settings(project, root, exclude)
              else
                project
              end
            end).()
        |> Store.Project.make_default_for_session()

      if is_nil(project.source_root) do
        {:error,
         """
         Error: the project root was not found in the settings file.

         This can happen under the following circumstances:
           - the first index of a project
           - the first index reindexing after moving the project directory
           - the first index after the upgrade that made --dir optional
         """}
      else
        %__MODULE__{
          opts: opts,
          indexer: Indexer.impl(),
          project: project
        }
        |> maybe_set_has_notes()
        |> then(&{:ok, &1})
      end
    end
  end

  defp maybe_set_has_notes(%{opts: %{has_notes?: has_notes?}} = idx)
       when is_boolean(has_notes?) do
    %{idx | has_notes?: has_notes?}
  end

  defp maybe_set_has_notes(idx) do
    Store.Project.Notes.read()
    |> case do
      {:ok, _} -> Map.put(idx, :has_notes?, true)
      {:error, :no_notes} -> Map.put(idx, :has_notes?, false)
    end
  end

  # ----------------------------------------------------------------------------
  # Indexing process
  # ----------------------------------------------------------------------------
  defp confirm_root_changed?(project, opts) do
    yes = Map.get(opts, :yes, false)
    user_dir_val = Map.get(opts, :directory)

    user_provided_dir? =
      case user_dir_val do
        nil -> false
        "" -> false
        _ -> true
      end

    new_directory =
      case user_dir_val do
        nil -> project.source_root
        dir -> Path.expand(dir)
      end

    cond do
      # If the user has passed --yes, assume confirmation. If we still don't
      # have a directory, default to the current working directory.
      yes ->
        {:ok, ensure_dir_for_yes(new_directory)}

      # When there is no project.root and the user did not explicitly pass
      # --dir, prompt whether to use the current directory as the project root.
      is_nil(project.source_root) and not user_provided_dir? ->
        prompt = """
        No directory specified. Would you like to use the current directory as the project root?

        Current directory: #{File.cwd!()}
        """

        UI.confirm(prompt, false)
        |> case do
          true -> {:ok, File.cwd!()}
          false -> {:error, :directory_required}
        end

      # If the project has no source root but the user explicitly supplied --dir,
      # just use that value (it will be validated later).
      is_nil(project.source_root) ->
        {:ok, new_directory}

      new_directory == project.source_root ->
        {:ok, new_directory}

      true ->
        UI.confirm(
          """
          You are about to index the project in a different directory.

          From: #{project.source_root}
            To: #{new_directory}

          This will overwrite the existing index. Do you want to continue?
          """,
          yes
        )
        |> case do
          true -> {:ok, new_directory}
          false -> {:error, :user_cancelled}
        end
    end
  end

  defp confirm_exclude_changed?(project, opts, root) do
    yes = Map.get(opts, :yes, false)

    new_exclude =
      Map.get(opts, :exclude)
      |> case do
        nil ->
          project.exclude

        [] ->
          project.exclude

        exclude ->
          Enum.map(exclude, fn path ->
            path
            |> Path.expand()
            |> Path.relative_to(root)
          end)
      end

    cond do
      yes ->
        {:ok, new_exclude}

      project.exclude == [] ->
        {:ok, new_exclude}

      new_exclude == project.exclude ->
        {:ok, new_exclude}

      true ->
        UI.confirm(
          """
          You are about to change the excluded paths for the project.

          From: #{Enum.join(project.exclude || [], ", ")}
            To: #{Enum.join(new_exclude, ", ")}

          This will overwrite the existing exclusions. Do you want to continue?
          """,
          yes
        )
        |> case do
          true -> {:ok, new_exclude}
          false -> {:error, :user_cancelled}
        end
    end
  end

  # Returns the provided directory if not nil, otherwise uses the current
  # working directory.
  defp ensure_dir_for_yes(nil) do
    File.cwd!()
  end

  defp ensure_dir_for_yes(dir) do
    dir
  end

  defp reindex?(idx), do: Map.get(idx.opts, :reindex, false)

  def index_project(idx) do
    # Ensure legacy entries are migrated to relative-path scheme before indexing
    Store.Project.Entry.MigrateAbsToRelPathKeys.ensure_relative_entry_ids(idx.project)

    project = maybe_reindex(idx)

    status =
      project
      |> scan_project()
      |> delete_entries()
      |> index_entries()

    # Each phase returns :ok on full success or {:partial, ok, err}. Aggregate
    # across phases so perform_task can propagate a non-zero exit code.
    phase_results = [
      status,
      index_commits(project),
      index_conversations(project),
      index_memories(),
      consolidate_samskaras(project)
    ]

    aggregate_phase_results(phase_results)
  end

  @spec consolidate_samskaras(Store.Project.t()) :: :ok
  defp consolidate_samskaras(project) do
    UI.spin("Consolidating samskaras", fn ->
      case AI.Agent.SamskaraConsolidator.run(project) do
        {:ok, %{consolidated: c, impressions: i}} ->
          {"Consolidated #{c} samskara(s) into #{i} impression(s)", :ok}

        {:ok, :noop} ->
          {"No samskaras to consolidate", :ok}

        {:error, reason} ->
          UI.warn("samskara consolidation failed", inspect(reason))
          {"Samskara consolidation skipped", :ok}
      end
    end)

    :ok
  end

  # Guards against fat-finger --workers values. Upper bound is 4x the
  # online scheduler count - well above what the BEAM can usefully
  # dispatch concurrently and still leaves headroom for pathological
  # I/O-bound workloads where oversubscribing helps. Clamping with a
  # warning beats letting the user spawn 1000 Task.Supervisor children
  # on a 4-core laptop.
  defp clamp_workers(n) do
    max = System.schedulers_online() * 4

    if n > max do
      UI.warn("--workers #{n} exceeds the safe ceiling (#{max}); clamping")
      max
    else
      n
    end
  end

  # Tells the user whether this invocation is indexing the default
  # branch's tree or the working tree. A developer on a feature branch
  # seeing "default branch: main" here has a clear signal that their
  # WIP changes aren't being indexed, which matches design intent but
  # is surprising without the callout.
  defp describe_source(project) do
    case Store.Project.Source.mode(project) do
      :git ->
        case Store.Project.Source.default_branch(project) do
          branch when is_binary(branch) -> "git default branch (#{branch})"
          _ -> "git default branch"
        end

      :fs ->
        "working tree"
    end
  end

  # Phases return :ok or {:partial, ok, err}. A bare :error from a future
  # phase would count as a single failure so it's visible in the exit code
  # rather than silently dropped.
  defp aggregate_phase_results(results) do
    {ok_total, err_total} =
      Enum.reduce(results, {0, 0}, fn
        :ok, acc -> acc
        {:partial, ok, err}, {ok_acc, err_acc} -> {ok_acc + ok, err_acc + err}
        :error, {ok_acc, err_acc} -> {ok_acc, err_acc + 1}
      end)

    if err_total == 0, do: :ok, else: {:partial, ok_total, err_total}
  end

  # Wraps per-item indexing work with a FileLock + a freshness re-check so
  # two concurrent `fnord index` sessions on the same project effectively
  # cooperate. Semantics:
  #
  #   - Acquire `FileLock.with_lock(lock_key, ...)`. Another worker
  #     (in-session or from a parallel fnord) holding the lock means the
  #     item is already being worked on, so we treat that as :skipped.
  #   - Inside the lock, call `still_stale?.()`. The recheck must happen
  #     *inside* the lock, not before it: a parallel worker can finish
  #     the item while we sit on the acquire, and an outside check would
  #     race ahead of the lock release and repeat the work.
  #   - Otherwise run `do_work.()`, which does the expensive summarize +
  #     embed + persist pipeline and returns :ok | :error | :binary.
  #
  # :skipped rolls into the same exit-code bucket as :ok: the phase is
  # still considered successful because the item is up-to-date on disk.
  @spec locked_task(String.t(), (-> boolean), (-> :ok | :error | :binary)) ::
          :ok | :error | :skipped | :binary
  defp locked_task(lock_key, still_stale?, do_work) do
    case FileLock.with_lock(lock_key, fn ->
           if still_stale?.(), do: do_work.(), else: :skipped
         end) do
      {:ok, result} ->
        result

      {:error, :lock_failed} ->
        :skipped

      {:callback_error, e} ->
        UI.error("indexing worker crashed", Exception.message(e))
        :error
    end
  end

  # Reduce an async_stream of per-item worker results into
  # {ok, skipped, binary, err}. Outcomes are distinct:
  #
  #   :ok       - the worker did the work successfully
  #   :skipped  - item was already fresh on disk (another worker beat
  #               us to it, or we lost the lock race). Not a failure.
  #   :binary   - file failed the UTF-8 guard; no entry is written.
  #               Reported separately so users can see "why the scan
  #               keeps showing 20 new" without confusing it with
  #               healthy freshness skips.
  #   :error    - real failure; counted toward phase partial-failure.
  #
  # Exit-code semantics: err == 0 -> :ok regardless of skipped/binary
  # counts. Both legitimate non-errors count toward the "successful
  # item" denominator for {:partial, _, _}.
  @spec reduce_phase(Enumerable.t(), String.t()) ::
          {String.t(), :ok | {:partial, non_neg_integer, non_neg_integer}}
  defp reduce_phase(stream, label) do
    {ok, err, skipped, binary} =
      Enum.reduce(stream, {0, 0, 0, 0}, fn
        {:ok, :ok}, {ok, err, skip, bin} -> {ok + 1, err, skip, bin}
        {:ok, :skipped}, {ok, err, skip, bin} -> {ok, err, skip + 1, bin}
        {:ok, :binary}, {ok, err, skip, bin} -> {ok, err, skip, bin + 1}
        {:ok, :error}, {ok, err, skip, bin} -> {ok, err + 1, skip, bin}
        _, {ok, err, skip, bin} -> {ok, err + 1, skip, bin}
      end)

    msg = format_phase_msg(label, ok, skipped, binary, err)
    phase = if err == 0, do: :ok, else: {:partial, ok + skipped + binary, err}
    {msg, phase}
  end

  defp format_phase_msg(label, ok, skipped, binary, err) do
    parts = ["Indexed #{ok} #{label}"]
    parts = if skipped > 0, do: parts ++ ["skipped #{skipped} already-fresh"], else: parts
    parts = if binary > 0, do: parts ++ ["#{binary} binary (not indexable)"], else: parts
    parts = if err > 0, do: parts ++ ["#{err} failed"], else: parts
    Enum.join(parts, "; ")
  end

  # Re-embed long-term memories (project + global) whose persisted embedding
  # is stale under the current model - either missing or of the wrong
  # dimension. Mirrors the file/commit/conversation phases: progress bar
  # under normal output, ✓/✗ per item under --quiet.
  @spec index_memories() :: :ok | {:partial, non_neg_integer, non_neg_integer}
  defp index_memories do
    stale = Memory.list_stale_long_term_memories()
    count = length(stale)

    if count == 0 do
      UI.info("No memories need reindexing")
      :ok
    else
      UI.spin("Indexing #{count} memory/memories", fn ->
        stale
        |> UI.async_stream(&process_memory/1, "Indexing")
        |> reduce_phase("memory/memories")
      end)
    end
  end

  defp process_memory({scope, title}) do
    lock_key =
      case Memory.lock_path(scope, title) do
        {:ok, path} -> path
        {:error, _} -> nil
      end

    if is_nil(lock_key) do
      # No project selected (for :project memories) - skip rather than fail.
      :skipped
    else
      locked_task(
        lock_key,
        fn -> Memory.stale?(scope, title) end,
        fn -> do_reindex_memory(scope, title) end
      )
    end
  end

  defp do_reindex_memory(scope, title) do
    case Memory.reindex_memory(scope, title) do
      :ok ->
        if Services.Globals.get_env(:fnord, :quiet) do
          UI.info("✓ <memory> [#{scope}] #{title}")
        end

        :ok

      {:error, reason} ->
        UI.error(
          "✗ <memory> [#{scope}] #{title}",
          inspect(reason, pretty: true, limit: :infinity)
        )

        :error
    end
  end

  @spec scan_project(Store.Project.t()) :: Store.Project.index_status()
  defp scan_project(project) do
    UI.spin("Scanning the project directory", fn ->
      status = Store.Project.index_status(project)

      msg = """
      Scan Results:
      - Stale:   #{Enum.count(status.stale)}
      - New:     #{Enum.count(status.new)}
      - Deleted: #{Enum.count(status.deleted)}
      """

      {msg, status}
    end)
  end

  @spec maybe_reindex(t) :: Store.Project.t()
  defp maybe_reindex(%{project: project} = idx) do
    if reindex?(idx) do
      Store.Project.delete(project)
      delete_commit_index(project)
      UI.report_step("Burned all of the old data to the ground to force a full reindex!")
    end

    project
  end

  defp delete_entries(%{deleted: deleted} = status) do
    UI.spin("Deleting missing and newly excluded files from index", fn ->
      Enum.each(deleted, &Store.Project.Entry.delete/1)
      count = Enum.count(deleted)
      {"Deleted #{count} file(s) from the index", status}
    end)
  end

  @spec index_entries(Store.Project.index_status()) :: :ok | {:partial, non_neg_integer, non_neg_integer}
  defp index_entries(%{new: new, stale: stale}) do
    files_to_index = new ++ stale
    count = Enum.count(files_to_index)

    if count == 0 do
      UI.warn("No files to index")
      :ok
    else
      UI.spin("Indexing #{count} file(s)", fn ->
        files_to_index
        |> UI.async_stream(&process_entry(&1), "Indexing")
        |> reduce_phase("file(s)")
      end)
    end
  end

  @spec index_conversations(Store.Project.t()) :: :ok | {:partial, non_neg_integer, non_neg_integer}
  defp index_conversations(project) do
    %{new: new, stale: stale, deleted: deleted} =
      Store.Project.ConversationIndex.index_status(project)

    UI.spin("Deleting missing conversations from index", fn ->
      Enum.each(deleted, &Store.Project.ConversationIndex.delete(project, &1))
      {"Deleted #{Enum.count(deleted)} conversation(s) from the index", :ok}
    end)

    conversations = new ++ stale
    count = Enum.count(conversations)

    if count == 0 do
      UI.warn("No conversations to index")
      :ok
    else
      UI.spin("Indexing #{count} conversation(s)", fn ->
        conversations
        |> UI.async_stream(&process_conversation(project, &1), "Indexing")
        |> reduce_phase("conversation(s)")
      end)
    end
  end

  defp process_conversation(project, convo) do
    locked_task(
      Store.Project.ConversationIndex.path_for(project, convo.id),
      fn -> Store.Project.ConversationIndex.stale?(project, convo) end,
      fn -> do_index_conversation(project, convo) end
    )
  end

  defp do_index_conversation(project, convo) do
    with {:ok, data} <- Store.Project.Conversation.read(convo),
         {:ok, summary} <- summarize_conversation(data.messages),
         {:ok, embeddings} <- Indexer.impl().get_embeddings(summary),
         :ok <-
           Store.Project.ConversationIndex.write_embeddings(
             project,
             convo.id,
             embeddings,
             Map.merge(data.metadata, %{
               "conversation_id" => convo.id,
               "last_indexed_ts" => DateTime.to_unix(data.timestamp),
               "message_count" => length(data.messages),
               "summary" => summary
             })
           ) do
      if Services.Globals.get_env(:fnord, :quiet) do
        UI.info("✓ <chat> #{convo.id}")
      end

      :ok
    else
      {:error, reason} ->
        UI.error(
          "✗ <chat> #{convo.id}",
          inspect(reason, pretty: true, limit: :infinity)
        )

        :error
    end
  end

  defp summarize_conversation(messages) do
    transcript =
      messages
      |> Enum.filter(fn msg -> Map.get(msg, "role") in ["user", "assistant"] end)
      |> Enum.map(fn msg ->
        role = Map.get(msg, "role", "unknown")
        content = extract_text_content(Map.get(msg, "content", ""))
        "#{role}: #{content}"
      end)
      |> Enum.join("\n\n")

    AI.Agent.ConversationSummary
    |> AI.Agent.new(named?: false)
    |> AI.Agent.get_response(%{transcript: transcript})
  end

  defp extract_text_content(content) when is_binary(content), do: content

  defp extract_text_content(content) when is_list(content) do
    content
    |> Enum.filter(fn
      %{"type" => "text"} -> true
      _ -> false
    end)
    |> Enum.map_join("\n", &Map.get(&1, "text", ""))
  end

  defp extract_text_content(_), do: ""

  defp process_entry(entry) do
    locked_task(
      entry.store_path,
      fn -> Store.Project.Entry.is_stale?(entry) end,
      fn -> do_index_entry(entry) end
    )
  end

  defp do_index_entry(entry) do
    case Indexer.index_entry(entry) do
      {:ok, _entry} ->
        if Services.Globals.get_env(:fnord, :quiet) do
          UI.info("✓ <file> #{entry.file}")
        end

        :ok

      # Binary files tracked in git would crash the summarizer's
      # UTF-8-only text splitter. Return :binary (distinct from :skipped,
      # which means "already fresh") so the phase message can report
      # them separately. We don't write a stored entry - so these files
      # reappear as "new" on every scan - because there's no honest
      # metadata to record for content the splitter can't process.
      {:error, :binary_file} ->
        if Services.Globals.get_env(:fnord, :quiet) do
          UI.info("⤳ <file> #{entry.file} (binary, not indexable)")
        end

        :binary

      {:error, reason} ->
        UI.error("✗ <file> #{entry.file}", inspect(reason, pretty: true, limit: :infinity))

        :error
    end
  end

  @prime_prompt """
  No research has been done yet for this project.
  Fnord uses notes from prior research to improve the quality of its answers.
  Would you like to prime the project with some initial research?
  """

  defp maybe_prime_notes(%{opts: %{quiet: true}} = idx), do: idx
  defp maybe_prime_notes(%{has_notes?: true} = idx), do: idx

  defp maybe_prime_notes(idx) do
    if UI.confirm(@prime_prompt, false) do
      Cmd.Prime.run(idx.opts, [], [])
    end
  end

  defp delete_commit_index(project) do
    project
    |> Store.Project.CommitIndex.root()
    |> File.rm_rf!()
  end

  @spec index_commits(Store.Project.t()) :: :ok | {:partial, non_neg_integer, non_neg_integer}
  defp index_commits(project) do
    case GitCli.is_git_repo_at?(project.source_root) do
      false ->
        UI.warn("Skipping commit indexing (not a git repository)")
        :ok

      true ->
        case Store.Project.CommitIndex.index_status(project) do
          %{deleted: deleted, new: new, stale: stale}
          when deleted == [] and new == [] and stale == [] ->
            UI.warn("No commits to index")
            :ok

          %{deleted: deleted, new: new, stale: stale} ->
            deleted_count = Enum.count(deleted)

            if deleted_count > 0 do
              UI.spin("Deleting missing commits from index", fn ->
                Enum.each(deleted, &Store.Project.CommitIndex.delete(project, &1))
                {"Deleted #{deleted_count} commit(s) from the index", :ok}
              end)
            end

            commits_to_index = new ++ stale
            count = Enum.count(commits_to_index)

            if count > 0 do
              UI.spin("Indexing #{count} commit(s)", fn ->
                commits_to_index
                |> UI.async_stream(&index_commit(project, &1), "Indexing")
                |> reduce_phase("commit(s)")
              end)
            else
              UI.warn("No commits to index")
              :ok
            end
        end
    end
  end

  @spec index_commit(Store.Project.t(), map()) :: :ok | :error | :skipped
  defp index_commit(project, commit) do
    locked_task(
      Store.Project.CommitIndex.path_for(project, commit.sha),
      fn -> Store.Project.CommitIndex.stale?(project, commit) end,
      fn -> do_index_commit(project, commit) end
    )
  end

  defp do_index_commit(project, commit) do
    %{document: document, metadata: metadata} = Store.Project.CommitIndex.build_metadata(commit)

    # Foreground commit indexing computes real embeddings for the canonical
    # commit document so `fnord index` produces usable vectors without relying
    # on a subsequent ask-session background refresh.
    with {:ok, embeddings} <- Indexer.impl().get_embeddings(document),
         :ok <- Store.Project.CommitIndex.write_embeddings(project, commit.sha, embeddings, metadata) do
      if Services.Globals.get_env(:fnord, :quiet) do
        UI.info("✓ <commit> #{String.slice(commit.sha, 0, 12)} #{commit.subject}")
      end

      :ok
    else
      {:error, reason} ->
        UI.error(
          "✗ <commit> #{String.slice(commit.sha, 0, 12)}",
          inspect(reason, pretty: true, limit: :infinity)
        )

        :error
    end
  end
end

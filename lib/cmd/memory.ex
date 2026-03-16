defmodule Cmd.Memory do
  @min_match_threshold 0.2

  alias Memory.Presentation

  @behaviour Cmd

  @impl Cmd
  def requires_project?(), do: false

  @impl Cmd
  def spec() do
    [
      memory: [
        name: "memory",
        about: "List memories or perform a semantic search across memory scopes",
        flags: [
          global: [
            long: "--global",
            short: "-g",
            help: "Use global (user) memories. If not set, project memories are used.",
            required: false,
            default: false
          ]
        ],
        options: [
          project: Cmd.project_arg(),
          query: [
            value_name: "QUERY",
            long: "--query",
            short: "-q",
            help: "Semantic search query. If omitted, all memories are shown.",
            required: false
          ]
        ],
        subcommands: [
          defrag: [
            name: "defrag",
            about: "Consolidate long-term memories (merge duplicates, prune redundancies)",
            options: [
              project: Cmd.project_arg()
            ]
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(_opts, [:defrag], _unknown) do
    run_defrag()
  end

  def run(opts, _subcommands, unknown) do
    if unknown != [] do
      UI.warn("Ignoring unknown arguments: #{Enum.join(unknown, " ")}")
    end

    scopes = resolve_scopes!(opts)

    markdown =
      case Map.get(opts, :query) do
        nil -> render_list(scopes)
        query -> render_search(scopes, query)
      end

    markdown
    |> UI.format()
    |> UI.puts()
  end

  # ----------------------------------------------------------------------------
  # Defrag (memory consolidation)
  # ----------------------------------------------------------------------------

  # Runs the memory consolidation pipeline with a spinner and progress bar.
  # Merges duplicate and redundant long-term memories across global and project
  # scopes in parallel.
  defp run_defrag do
    total = count_long_term_memories()

    if total == 0 do
      UI.warn("No long-term memories to consolidate")
      :ok
    else
      UI.spin("Consolidating #{total} long-term memories", fn ->
        UI.progress_bar_start(:consolidation, "Consolidating", total)
        on_progress = fn -> UI.progress_bar_update(:consolidation) end

        case Memory.Consolidator.run(on_progress: on_progress) do
          {:ok, report} ->
            msg =
              "Merged: #{report.merged}, Deleted: #{report.deleted}, " <>
                "Kept: #{report.kept}, Errors: #{report.errors}"

            {msg, :ok}

          {:error, reason} ->
            {"Failed: #{inspect(reason)}", {:error, reason}}
        end
      end)
    end
  end

  defp count_long_term_memories do
    global =
      case Memory.list(:global) do
        {:ok, l} -> length(l)
        _ -> 0
      end

    project =
      case Memory.list(:project) do
        {:ok, l} -> length(l)
        _ -> 0
      end

    global + project
  end

  # ----------------------------------------------------------------------------
  # Listing
  # ----------------------------------------------------------------------------

  defp render_list(scopes) do
    sections =
      scopes
      |> Enum.map(fn scope ->
        case available?(scope) do
          true ->
            {:ok, memories} = list_memories(scope)

            rendered_memories =
              memories
              |> Enum.sort_by(& &1.title)
              |> Enum.map(fn memory ->
                {memory, nil}
              end)

            render_scope_section(scope, rendered_memories, %{mode: :list})

          false ->
            render_unavailable_scope_section(scope)
        end
      end)

    """
    # Memories

    #{Enum.join(sections, "\n\n")}
    """
  end

  # ----------------------------------------------------------------------------
  # Search
  # ----------------------------------------------------------------------------

  defp render_search(scopes, query) when is_binary(query) do
    query = String.trim(query)

    case Indexer.impl().get_embeddings(query) do
      {:ok, needle} ->
        sections =
          scopes
          |> Enum.map(fn scope ->
            if available?(scope) do
              {:ok, titles} = list_titles(scope)

              {matches, stale_count} =
                titles
                |> Enum.reduce({[], 0}, fn title, {acc, stale} ->
                  case Memory.read(scope, title) do
                    {:ok, %Memory{embeddings: nil}} ->
                      {acc, stale + 1}

                    {:ok, %Memory{embeddings: embeddings} = mem} ->
                      score = AI.Util.cosine_similarity(needle, embeddings)

                      if score > @min_match_threshold do
                        {[{mem, score} | acc], stale}
                      else
                        {acc, stale}
                      end

                    {:error, _} ->
                      {acc, stale}
                  end
                end)

              matches = Enum.sort_by(matches, fn {_mem, score} -> score end, :desc)
              render_scope_section(scope, matches, %{mode: :search, stale_count: stale_count})
            else
              render_unavailable_scope_section(scope)
            end
          end)

        """
        # Memories

        #{Enum.join(sections, "\n\n")}
        """

      {:error, reason} ->
        """
        # Memories

        Failed to generate embeddings for query: #{inspect(reason)}
        """
    end
  end

  # ----------------------------------------------------------------------------
  # Markdown formatting
  # ----------------------------------------------------------------------------

  defp render_scope_section(scope, memories, %{mode: :list}) do
    body =
      case memories do
        [] ->
          "_No memories._"

        _ ->
          memories
          |> Enum.map(&render_memory/1)
          |> Enum.join("\n\n")
      end

    """
    ## #{scope}

    #{body}
    """
  end

  defp render_scope_section(scope, memories, %{mode: :search, stale_count: stale_count}) do
    stale_note =
      if stale_count > 0 do
        "_Skipped #{stale_count} stale memorie(s) missing embeddings._"
      else
        ""
      end

    body =
      case memories do
        [] ->
          "_No matches._\n"

        _ ->
          memories
          |> Enum.map(&render_memory/1)
          |> Enum.join("\n\n")
      end

    """
    ## #{scope}

    #{stale_note}

    #{body}
    """
  end

  defp render_unavailable_scope_section(scope) do
    """
    ## #{scope}

    _Unavailable in the current context._
    """
  end

  defp render_memory({%Memory{} = mem, nil}) do
    now = DateTime.utc_now()
    age = Presentation.age_line(mem, now)
    warning = Presentation.warning_line(mem, now)

    """
    ### [#{mem.scope}] #{mem.title}
    _#{age}_
    _#{warning}_

    #{mem.content}
    """
  end

  defp render_memory({%Memory{} = mem, score}) when is_number(score) do
    now = DateTime.utc_now()
    age = Presentation.age_line(mem, now)
    warning = Presentation.warning_line(mem, now)

    """
    ### #{mem.title}
    _Score:_ #{Float.round(score, 4)}
    _#{age}_
    _#{warning}_

    #{mem.content}
    """
  end

  # ----------------------------------------------------------------------------
  # Scope resolution
  # ----------------------------------------------------------------------------

  defp resolve_scopes!(%{global: true}), do: [:global]

  defp resolve_scopes!(opts) do
    maybe_set_project(opts)

    case Settings.get_selected_project() do
      {:ok, _project} ->
        [:project]

      {:error, _reason} ->
        UI.fatal(
          "No project selected; use --project or run in a project directory, or pass --global."
        )

        exit({:shutdown, 1})
    end
  end

  defp maybe_set_project(%{project: project}) when is_binary(project) and project != "" do
    Settings.set_project(project)
    :ok
  end

  defp maybe_set_project(_), do: :ok

  defp available?(:global), do: true
  defp available?(:project), do: Memory.Project.is_available?()

  defp list_memories(:global), do: Memory.Global.list_memories()
  defp list_memories(:project), do: Memory.Project.list_memories()

  defp list_titles(:global), do: Memory.Global.list()
  defp list_titles(:project), do: Memory.Project.list()
end

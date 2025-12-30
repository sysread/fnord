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
        options: [
          scope: [
            value_name: "SCOPE",
            long: "--scope",
            short: "-s",
            help: "Limit to scope(s): global, project (may be repeated)",
            required: false,
            multiple: true
          ],
          query: [
            value_name: "QUERY",
            long: "--query",
            short: "-q",
            help: "Semantic search query. If omitted, all memories are shown.",
            required: false
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(opts, _subcommands, unknown) do
    if unknown != [] do
      UI.warn("Ignoring unknown arguments: #{Enum.join(unknown, " ")}")
    end

    scopes = parse_scopes(Map.get(opts, :scope))

    markdown =
      case Map.get(opts, :query) do
        nil -> render_list(scopes)
        query -> render_search(scopes, query)
      end

    markdown
    |> UI.Formatter.format_output()
    |> UI.puts()
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
            {:ok, titles} = list_titles(scope)

            memories =
              titles
              |> Enum.sort()
              |> Enum.map(fn title ->
                {:ok, mem} = Memory.read(scope, title)
                {mem, nil}
              end)

            render_scope_section(scope, memories, %{mode: :list})

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
  # Scope helpers
  # ----------------------------------------------------------------------------

  defp parse_scopes(nil), do: [:global, :project]
  defp parse_scopes([]), do: [:global, :project]

  defp parse_scopes(scopes) when is_list(scopes) do
    scopes
    |> Enum.map(&parse_scope!/1)
    |> Enum.uniq()
    |> Enum.sort_by(&scope_order/1)
  end

  defp parse_scope!(s) when is_binary(s) do
    case String.downcase(s) do
      "global" ->
        :global

      "project" ->
        :project

      other ->
        UI.fatal("Invalid --scope #{inspect(other)}; expected global, project")
        exit({:shutdown, 1})
    end
  end

  defp scope_order(:global), do: 1
  defp scope_order(:project), do: 2

  defp available?(:global), do: true
  defp available?(:project), do: Memory.Project.is_available?()

  defp list_titles(:global), do: Memory.Global.list()
  defp list_titles(:project), do: Memory.Project.list()
end

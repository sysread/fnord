defmodule Cmd.Samskara do
  @moduledoc """
  Inspect and debug the samskara store for the current project.
  """

  @behaviour Cmd

  alias Store.Project.Samskara

  @impl Cmd
  def requires_project?(), do: true

  @impl Cmd
  def spec do
    [
      samskara: [
        name: "samskara",
        about: "Inspect stored samskaras for the current project",
        subcommands: [
          status: [
            name: "status",
            about: "Show samskara count and consolidation backlog",
            options: [project: Cmd.project_arg()]
          ],
          list: [
            name: "list",
            about: "List active samskaras (id, minted_at, reaction, gist)",
            options: [
              project: Cmd.project_arg(),
              limit: [
                value_name: "LIMIT",
                long: "--limit",
                short: "-l",
                help: "Max rows to show",
                parser: :integer,
                default: 50
              ]
            ],
            flags: [
              all: [
                long: "--all",
                short: "-a",
                help: "Include superseded records",
                required: false
              ]
            ]
          ],
          show: [
            name: "show",
            about: "Print a full samskara JSON record by id",
            args: [
              id: [value_name: "ID", help: "Samskara id", required: true]
            ],
            options: [project: Cmd.project_arg()]
          ],
          fires: [
            name: "fires",
            about: "Debug firing: show which samskaras fire for free-text input",
            args: [
              query: [value_name: "QUERY", help: "Free-text query", required: true]
            ],
            options: [
              project: Cmd.project_arg(),
              limit: [
                value_name: "LIMIT",
                long: "--limit",
                short: "-l",
                help: "Max firings to show",
                parser: :integer,
                default: 5
              ]
            ]
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(_opts, [:status], _unknown) do
    with {:ok, project} <- Store.get_project() do
      all = Samskara.list(project)
      active = Enum.reject(all, & &1.superseded)
      impressions = Enum.filter(all, & &1.impression?)
      unconsolidated = Samskara.list_unconsolidated(project)

      last =
        case active do
          [] -> "never"
          [%{minted_at: ts} | _] -> DateTime.to_iso8601(ts)
        end

      UI.puts("""
      Samskara store: #{project.samskara_dir}
        total records:        #{length(all)}
        active (non-superseded): #{length(active)}
        impressions:          #{length(impressions)}
        unconsolidated:       #{length(unconsolidated)}
        most recent mint:     #{last}
      """)
    else
      {:error, reason} -> UI.error("Error: #{inspect(reason)}")
    end
  end

  def run(opts, [:list], _unknown) do
    limit = Map.get(opts, :limit, 50)
    show_all? = Map.get(opts, :all, false)

    with {:ok, project} <- Store.get_project() do
      records =
        if show_all?, do: Samskara.list(project), else: Samskara.list_active(project)

      records
      |> Enum.take(limit)
      |> Enum.each(fn r ->
        UI.puts("#{r.id}\t#{DateTime.to_iso8601(r.minted_at)}\t#{r.reaction}\t#{truncate(r.gist, 80)}")
      end)
    else
      {:error, reason} -> UI.error("Error: #{inspect(reason)}")
    end
  end

  def run(%{id: id}, [:show], _unknown) do
    with {:ok, project} <- Store.get_project(),
         {:ok, record} <- Samskara.get(project, id) do
      record
      |> Store.Project.Samskara.Record.to_json_map()
      |> SafeJson.encode!(pretty: true)
      |> UI.puts()
    else
      {:error, :not_found} -> UI.error("Samskara not found")
      {:error, reason} -> UI.error("Error: #{inspect(reason)}")
    end
  end

  def run(%{query: query} = opts, [:fires], _unknown) do
    limit = Map.get(opts, :limit, 5)

    with {:ok, project} <- Store.get_project(),
         {:ok, scored} <- AI.Samskara.Firing.for_text(project, query, limit) do
      case scored do
        [] ->
          UI.puts("(no samskaras fire for this query)")

        _ ->
          Enum.each(scored, fn {r, score} ->
            UI.puts("#{Float.round(score, 3)}\t#{r.id}\t#{r.reaction}\t#{truncate(r.gist, 80)}")
          end)
      end
    else
      {:error, reason} -> UI.error("Error: #{inspect(reason)}")
    end
  end

  def run(_opts, [], _unknown) do
    UI.error("No subcommand specified. Use 'fnord samskara --help' for help.")
  end

  def run(_opts, _subcommands, _unknown) do
    UI.error("Unknown subcommand. Use 'fnord samskara --help' for help.")
  end

  defp truncate(nil, _), do: ""
  defp truncate(str, max) when is_binary(str) do
    if String.length(str) > max do
      String.slice(str, 0, max - 1) <> "…"
    else
      str
    end
  end
end

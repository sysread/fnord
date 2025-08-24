defmodule Cmd.Config do
  @behaviour Cmd

  @impl Cmd
  def requires_project?(), do: false

  @impl Cmd
  def spec do
    [
      config: [
        name: "config",
        about: "Manage configuration settings",
        subcommands: [
          list: [
            name: "list",
            about: "List configuration settings (global or project-specific)",
            options: [
              project: Cmd.project_arg()
            ]
          ],
          set: [
            name: "set",
            about: "Set a configuration directive for a project",
            options: [
              project: Cmd.project_arg(),
              root: [
                value_name: "ROOT",
                long: "--root",
                short: "-r",
                help: "Root directory for the project",
                required: false
              ],
              exclude: [
                value_name: "EXCLUDE",
                long: "--exclude",
                short: "-x",
                help: "Exclude files from the project",
                required: false,
                multiple: true
              ]
            ]
          ],
          approvals: [
            name: "approvals",
            about: "List approval patterns (global or project)",
            options: [
              project: Cmd.project_arg()
            ],
            flags: [
              global: [
                long: "--global",
                short: "-g",
                help: "Use global approvals",
                required: false
              ]
            ]
          ],
          approve: [
            name: "approve",
            about: "Add an approval regex under a kind (scope: global|project)",
            args: [
              pattern: [
                value_name: "PATTERN",
                help: "Regex to approve",
                required: true
              ]
            ],
            options: [
              project: Cmd.project_arg(),
              kind: [
                value_name: "KIND",
                long: "--kind",
                short: "-k",
                help: "Approval kind",
                required: true
              ]
            ],
            flags: [
              global: [
                long: "--global",
                short: "-g",
                help: "Add to global scope. If not set, new patterns are added to project scope.",
                required: false
              ]
            ]
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(_opts, [:list], _unknown) do
    settings = Settings.new()

    global = %{
      "approvals" => Settings.Approvals.get_approvals(settings, :global)
    }

    with {:ok, project} <- Store.get_project() do
      case Settings.get_project_data(settings, project.name) do
        nil ->
          UI.error("Project not found")

        config ->
          global
          |> Map.merge(config)
          |> Jason.encode!(pretty: true)
          |> IO.puts()
      end
    else
      {:error, _} -> UI.error("Project not found")
    end
  end

  def run(opts, [:set], _unknown) do
    case opts[:project] do
      nil ->
        UI.error("Project option is required for set command. Use --project PROJECT_NAME.")

      project_name ->
        Settings.set_project(project_name)

        with {:ok, project} <- Store.get_project() do
          if !Store.Project.exists_in_store?(project) do
            UI.error("""
            Project '#{project.name}' does not exist.
            Please create it with: `fnord index`
            """)
          else
            Store.Project.save_settings(project, opts[:root], opts[:exclude])
            run(opts, [:list], [])
          end
        else
          {:error, _} -> UI.error("Project not found")
        end
    end
  end

  @impl Cmd
  def run(opts, [:approvals], _unknown) do
    cond do
      opts[:global] && opts[:project] ->
        build_list()
        |> Jason.encode!(pretty: true)
        |> IO.puts()

      opts[:global] ->
        build_list(:global)
        |> Jason.encode!(pretty: true)
        |> IO.puts()

      true ->
        case Settings.get_selected_project() do
          {:ok, _proj} ->
            build_list(:project)
            |> Jason.encode!(pretty: true)
            |> IO.puts()

          {:error, _} ->
            UI.error("Project not specified or not found")
        end
    end
  end

  @impl Cmd
  def run(opts, [:approve], [pattern]) do
    cond do
      opts[:global] && opts[:project] ->
        UI.error("Cannot use both --global and --project.")

      is_nil(opts[:kind]) ->
        UI.error("Missing --kind option.")

      true ->
        scope = if opts[:global], do: :global, else: :project
        if scope == :project && opts[:project], do: Settings.set_project(opts[:project])
        settings = Settings.new()

        case build_approve(settings, scope, opts[:kind], pattern) do
          {:ok, data} ->
            data
            |> Jason.encode!(pretty: true)
            |> IO.puts()

          {:error, msg} ->
            UI.error(msg)
        end
    end
  end

  def run(_opts, [], _unknown) do
    UI.error("No subcommand specified. Use 'fnord help config' for help.")
  end

  def run(_opts, _subcommands, _unknown) do
    UI.error("Unknown subcommand. Use 'fnord help config' for help.")
  end

  defp build_list(:global) do
    Settings.new()
    |> Settings.Approvals.get_approvals(:global)
  end

  defp build_list(:project) do
    Settings.new()
    |> Settings.Approvals.get_approvals(:project)
  end

  defp build_list() do
    global = build_list(:global)
    project = build_list(:project)

    Enum.concat([
      Map.keys(global),
      Map.keys(project)
    ])
    |> Enum.uniq()
    |> Enum.map(fn kind ->
      {
        kind,
        %{
          global: Map.get(global, kind, []),
          project: Map.get(project, kind, [])
        }
      }
    end)
    |> Enum.into(%{})
  end

  defp build_approve(settings, scope, kind, pattern) do
    try do
      new_settings = Settings.Approvals.approve(settings, scope, kind, pattern)
      patterns = Settings.Approvals.get_approvals(new_settings, scope, kind)
      {:ok, %{kind => patterns}}
    rescue
      e in Regex.CompileError ->
        {:error, "Invalid regex: #{e.message}"}
    end
  end
end

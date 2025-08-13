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
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(opts, [:list], _unknown) do
    settings = Settings.new()

    case opts[:project] do
      nil ->
        global_config = %{
          "approvals" => Settings.get_approvals(settings, :global)
        }

        global_config |> Jason.encode!(pretty: true) |> IO.puts()

      project_name ->
        Settings.set_project(project_name)

        with {:ok, project} <- Store.get_project() do
          case Settings.get_project_data(settings, project.name) do
            nil -> UI.error("Project not found")
            config -> config |> Jason.encode!(pretty: true) |> IO.puts()
          end
        else
          {:error, _} -> UI.error("Project not found")
        end
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

  def run(_opts, [], _unknown) do
    UI.error("No subcommand specified. Use 'fnord help config' for help.")
  end

  def run(_opts, _subcommands, _unknown) do
    UI.error("Unknown subcommand. Use 'fnord help config' for help.")
  end
end

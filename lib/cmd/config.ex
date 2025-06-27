defmodule Cmd.Config do
  @behaviour Cmd

  @impl Cmd
  def requires_project?(), do: true

  @impl Cmd
  def spec do
    [
      config: [
        name: "config",
        about: "Manage configuration settings",
        subcommands: [
          list: [
            name: "list",
            about: "List all configuration settings for a project",
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
  def run(_opts, [:list], _unknown) do
    with {:ok, project} <- Store.get_project() do
      Settings.new()
      |> Settings.get(project.name)
      |> case do
        nil -> UI.error("Project not found")
        config -> config |> Jason.encode!(pretty: true) |> IO.puts()
      end
    end
  end

  def run(opts, [:set], _unknown) do
    with {:ok, project} <- Store.get_project() do
      Store.Project.save_settings(project, opts[:root], opts[:exclude])
      run(opts, [:list], [])
    end
  end

  def run(_opts, [], _unknown) do
    UI.error("No subcommand specified. Use 'fnord help config' for help.")
  end
end

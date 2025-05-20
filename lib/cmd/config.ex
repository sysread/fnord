defmodule Cmd.Config do
  @behaviour Cmd

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
              project: [
                value_name: "PROJECT",
                long: "--project",
                short: "-p",
                help: "Project name",
                required: true
              ]
            ]
          ],
          set: [
            name: "set",
            about: "Set a configuration directive for a project",
            options: [
              project: [
                value_name: "PROJECT",
                long: "--project",
                short: "-p",
                help: "Project name",
                required: true
              ],
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
  def run(%{project: project}, [:list], _unknown) do
    Settings.new()
    |> Settings.get(project)
    |> case do
      nil -> UI.error("Project not found")
      config -> config |> Jason.encode!(pretty: true) |> IO.puts()
    end
  end

  def run(opts, [:set], _unknown) do
    project = Store.get_project()
    Store.Project.save_settings(project, opts[:root], opts[:exclude])
    run(opts, [:list], [])
  end

  def run(_opts, [], _unknown) do
    UI.error("No subcommand specified. Use 'fnord help config' for help.")
  end
end

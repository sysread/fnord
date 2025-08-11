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
          "approved-commands": [
            name: "approved-commands",
            about: "Manage approved commands",
            subcommands: [
              list: [
                name: "list",
                about: "List approved commands (global or project-specific)",
                options: [
                  project: Cmd.project_arg()
                ]
              ],
              approve: [
                name: "approve",
                about: "Approve a command for execution",
                args: [
                  command: [
                    value_name: "COMMAND",
                    help: "Command to approve",
                    required: true
                  ]
                ],
                options: [
                  project: Cmd.project_arg()
                ]
              ],
              deny: [
                name: "deny",
                about: "Deny a command for execution",
                args: [
                  command: [
                    value_name: "COMMAND",
                    help: "Command to deny",
                    required: true
                  ]
                ],
                options: [
                  project: Cmd.project_arg()
                ]
              ],
              remove: [
                name: "remove",
                about: "Remove a command from approval list",
                args: [
                  command: [
                    value_name: "COMMAND",
                    help: "Command to remove",
                    required: true
                  ]
                ],
                options: [
                  project: Cmd.project_arg()
                ]
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
          "approved_commands" => Settings.get_approved_commands(settings, :global)
        }

        global_config |> Jason.encode!(pretty: true) |> IO.puts()

      project_name ->
        Settings.set_project(project_name)

        with {:ok, project} <- Store.get_project() do
          case Settings.get(settings, project.name) do
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

  def run(opts, ["approved-commands", "list"], _unknown) do
    settings = Settings.new()

    case opts[:project] do
      nil ->
        global_commands = Settings.get_approved_commands(settings, :global)
        IO.puts("Global approved commands:")

        if Enum.empty?(global_commands) do
          IO.puts("  (none)")
        else
          Enum.each(global_commands, fn {command, approved} ->
            status = if approved, do: "✓ approved", else: "✗ denied"
            IO.puts("  #{command}: #{status}")
          end)
        end

      project_name ->
        Settings.set_project(project_name)

        with {:ok, project} <- Store.get_project() do
          project_commands = Settings.get_approved_commands(settings, project.name)
          global_commands = Settings.get_approved_commands(settings, :global)

          IO.puts("Project '#{project.name}' approved commands:")

          if Enum.empty?(project_commands) do
            IO.puts("  (none)")
          else
            Enum.each(project_commands, fn {command, approved} ->
              status = if approved, do: "✓ approved", else: "✗ denied"
              IO.puts("  #{command}: #{status}")
            end)
          end

          unless Enum.empty?(global_commands) do
            IO.puts("")
            IO.puts("Inherited from global:")

            Enum.each(global_commands, fn {command, approved} ->
              case Map.get(project_commands, command) do
                nil ->
                  status = if approved, do: "✓ approved", else: "✗ denied"
                  IO.puts("  #{command}: #{status}")

                _ ->
                  # Skip commands that are overridden at project level
                  nil
              end
            end)
          end
        else
          {:error, _} -> UI.error("Project not found")
        end
    end
  end

  def run(opts, ["approved-commands", "approve", command], _unknown) do
    settings = Settings.new()

    case opts[:project] do
      nil ->
        Settings.set_command_approval(settings, :global, command, true)
        IO.puts("Command '#{command}' approved globally.")

      project_name ->
        Settings.set_project(project_name)

        with {:ok, project} <- Store.get_project() do
          Settings.set_command_approval(settings, project.name, command, true)
          IO.puts("Command '#{command}' approved for project '#{project.name}'.")
        else
          {:error, _} -> UI.error("Project not found")
        end
    end
  end

  def run(opts, ["approved-commands", "deny", command], _unknown) do
    settings = Settings.new()

    case opts[:project] do
      nil ->
        Settings.set_command_approval(settings, :global, command, false)
        IO.puts("Command '#{command}' denied globally.")

      project_name ->
        Settings.set_project(project_name)

        with {:ok, project} <- Store.get_project() do
          Settings.set_command_approval(settings, project.name, command, false)
          IO.puts("Command '#{command}' denied for project '#{project.name}'.")
        else
          {:error, _} -> UI.error("Project not found")
        end
    end
  end

  def run(opts, ["approved-commands", "remove", command], _unknown) do
    settings = Settings.new()

    case opts[:project] do
      nil ->
        Settings.remove_command_approval(settings, :global, command)
        IO.puts("Command '#{command}' removed from global approval list.")

      project_name ->
        Settings.set_project(project_name)

        with {:ok, project} <- Store.get_project() do
          Settings.remove_command_approval(settings, project.name, command)
          IO.puts("Command '#{command}' removed from project '#{project.name}' approval list.")
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

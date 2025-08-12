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
            about: "Manage command approvals",
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
                  project: Cmd.project_arg(),
                  tag: [
                    value_name: "TAG",
                    long: "--tag",
                    short: "-t",
                    help: "Tag for command categorization (default: shell_cmd)",
                    required: false
                  ]
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
                  project: Cmd.project_arg(),
                  tag: [
                    value_name: "TAG",
                    long: "--tag",
                    short: "-t",
                    help: "Tag for command categorization (default: shell_cmd)",
                    required: false
                  ]
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
                  project: Cmd.project_arg(),
                  tag: [
                    value_name: "TAG",
                    long: "--tag",
                    short: "-t",
                    help: "Tag for command categorization (default: shell_cmd)",
                    required: false
                  ]
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

  def run(opts, [:approvals, :list], _unknown) do
    settings = Settings.new()

    case opts[:project] do
      nil ->
        global_commands = Settings.get_approved_commands(settings, :global)
        IO.puts("Global approved commands:")

        if Enum.empty?(global_commands) do
          IO.puts("  (none)")
        else
          Enum.each(global_commands, fn {tag, command_list} ->
            Enum.each(command_list, fn command ->
              IO.puts("  #{tag}##{command}: ✓ approved")
            end)
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
            Enum.each(project_commands, fn {tag, command_list} ->
              Enum.each(command_list, fn command ->
                IO.puts("  #{tag}##{command}: ✓ approved")
              end)
            end)
          end

          unless Enum.empty?(global_commands) do
            IO.puts("")
            IO.puts("Inherited from global:")

            Enum.each(global_commands, fn {tag, command_list} ->
              project_tag_commands = Map.get(project_commands, tag, [])

              Enum.each(command_list, fn command ->
                unless command in project_tag_commands do
                  IO.puts("  #{tag}##{command}: ✓ approved")
                end
              end)
            end)
          end
        else
          {:error, _} -> UI.error("Project not found")
        end
    end
  end

  def run(opts, [:approvals, :approve], _unknown) do
    settings = Settings.new()
    # Arguments come through opts
    command = opts[:command]
    {tag, command_parts} = parse_command_for_approval(command, opts[:tag])

    case opts[:project] do
      nil ->
        Settings.add_approved_command(settings, :global, tag, command_parts)
        IO.puts("Command '#{command}' approved globally with tag '#{tag}'.")

      project_name ->
        Settings.set_project(project_name)

        with {:ok, project} <- Store.get_project() do
          Settings.add_approved_command(settings, project.name, tag, command_parts)

          IO.puts(
            "Command '#{command}' approved for project '#{project.name}' with tag '#{tag}'."
          )
        else
          {:error, _} -> UI.error("Project not found")
        end
    end
  end

  def run(_opts, [:approvals, :deny], _unknown) do
    UI.error("Deny functionality has been removed. Use 'remove' to remove approved commands.")
  end

  def run(opts, [:approvals, :remove], _unknown) do
    settings = Settings.new()
    # Arguments come through opts
    command = opts[:command]
    {tag, command_parts} = parse_command_for_approval(command, opts[:tag])

    case opts[:project] do
      nil ->
        Settings.remove_approved_command(settings, :global, tag, command_parts)
        IO.puts("Command '#{command}' removed from global approval list for tag '#{tag}'.")

      project_name ->
        Settings.set_project(project_name)

        with {:ok, project} <- Store.get_project() do
          Settings.remove_approved_command(settings, project.name, tag, command_parts)

          IO.puts(
            "Command '#{command}' removed from project '#{project.name}' approval list for tag '#{tag}'."
          )
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

  # Parse command into tag and command parts for approval system
  # Uses provided tag or defaults to "shell_cmd" to match shell tool behavior
  defp parse_command_for_approval(command, tag) do
    tag = tag || "shell_cmd"
    {tag, command}
  end
end

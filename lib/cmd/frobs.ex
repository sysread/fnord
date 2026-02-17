defmodule Cmd.Frobs do
  @behaviour Cmd

  @impl Cmd
  def requires_project?(), do: false

  @impl Cmd
  def spec do
    [
      frobs: [
        name: "frobs",
        about: "Manages external tool call integrations (frobs)",
        subcommands: [
          create: [
            name: "create",
            about: "Creates a new frob",
            options: [
              name: [
                value_name: "NAME",
                long: "--name",
                short: "-n",
                help: "Name of the frob",
                required: true
              ]
            ]
          ],
          check: [
            name: "check",
            about: "Validates a frob",
            options: [
              name: [
                value_name: "NAME",
                long: "--name",
                short: "-n",
                help: "Name of the frob",
                required: true
              ]
            ]
          ],
          list: [
            name: "list",
            about: "Lists available frobs (use -a / --all to list all frobs)",
            flags: [
              all: [
                long: "--all",
                short: "-a",
                help: "List all frobs, including disabled ones"
              ]
            ]
          ],
          enable: [
            name: "enable",
            about: "Enables a frob",
            options: [
              name: [
                value_name: "NAME",
                long: "--name",
                short: "-n",
                help: "Name of the frob",
                required: true
              ],
              global: [
                long: "--global",
                help: "Apply to global settings (otherwise current project)",
                takes_value: false
              ],
              project: [
                long: "--project",
                value_name: "PROJECT",
                help: "Apply to the named project (overrides selected project)"
              ]
            ]
          ],
          disable: [
            name: "disable",
            about: "Disables a frob",
            options: [
              name: [
                value_name: "NAME",
                long: "--name",
                short: "-n",
                help: "Name of the frob",
                required: true
              ],
              global: [
                long: "--global",
                help: "Apply to global settings (otherwise current project)",
                takes_value: false
              ],
              project: [
                long: "--project",
                value_name: "PROJECT",
                help: "Apply to the named project (overrides selected project)"
              ]
            ]
          ],
          call: [
            name: "call",
            about: "Interactively test a frob by prompting for parameters and executing it",
            options: [
              name: [
                value_name: "NAME",
                long: "--name",
                short: "-n",
                help: "Name of the frob",
                required: true
              ],
              project: [
                long: "--project",
                value_name: "PROJECT",
                help: "Project name (overrides auto-resolve)"
              ]
            ]
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(opts, subcommands, _unknown) do
    Services.Once.set(:frobs_cli_used, true)

    try do
      with {:ok, msg} <- call_subcommand(subcommands, opts) do
        UI.puts(msg)
      else
        {:error, :invalid_subcommand} ->
          UI.fatal("Invalid subcommand. Use `fnord help frobs` for available commands.")

        {:error, reason} ->
          UI.fatal("Error: #{reason}")
      end
    rescue
      e in RuntimeError ->
        UI.fatal("Error: #{e.message}")
    end
  end

  defp call_subcommand(subcommands, opts) do
    case subcommands do
      [:create] -> create(opts)
      [:check] -> check(opts)
      [:list] -> list(opts)
      [:enable] -> enable(opts)
      [:disable] -> disable(opts)
      [:call] -> call_frob(opts)
      _ -> {:error, :invalid_subcommand}
    end
  end

  defp call_frob(opts) do
    name = opts[:name] || raise("--name is required")

    project =
      if is_binary(opts[:project]) and byte_size(opts[:project]) > 0 do
        {:ok, opts[:project]}
      else
        ResolveProject.resolve()
      end

    with {:ok, _project} <- project,
         {:ok, frob} <- Frobs.load(name) do
      unless Settings.Frobs.enabled?(frob.name) do
        {:error, "Frob '#{frob.name}' is disabled in settings"}
      else
        args_map =
          UI.interact(fn ->
            case Frobs.Prompt.prompt_for_params(frob.spec, UI) do
              {:ok, m} -> m
              other -> raise("Prompt error: #{inspect(other)}")
            end
          end)

        case Frobs.perform_tool_call(name, Jason.encode!(args_map)) do
          {:ok, output} -> {:ok, output}
          {:error, exit_code, out} -> {:error, "exited with status #{exit_code}: #{out}"}
          other -> {:error, "unexpected tool call result: #{inspect(other)}"}
        end
      end
    else
      {:error, :not_in_project} -> {:error, "Not in a project and --project not given"}
      {:error, :frob_not_found} -> {:error, "Frob not found: #{name}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create(%{name: name}) do
    with {:ok, frob} <- Frobs.create(name) do
      {:ok,
       """
       --------------------------------------------------------------------------------
       > Frob created
       --------------------------------------------------------------------------------
       - Name:     `#{frob.name}`
       - Home:     `#{frob.home}`
       - Spec:     `#{frob.home}/spec.json`
       - Main:     `#{frob.home}/main`
       --------------------------------------------------------------------------------
       > Tips
       --------------------------------------------------------------------------------
       - Edit `main` to implement your integration.
       - Update the spec in `spec.json` to define the frob's interface and parameters.
       - Enable your frob via the settings CLI or the Settings.Frobs module.

       Fnord communicates run-time information to the frob via environment variables:
           - FNORD_PROJECT:    The name of the currently selected project
           - FNORD_CONFIG:     JSON object of project config (see `$HOME/.fnord/settings.json`)
           - FNORD_ARGS_JSON:  JSON object of LLM-provided arguments (defined in your spec)

       !!! You can remove the frob at any time by deleting the directory.
       """}
    end
  end

  defp check(%{name: name}) do
    with {:ok, _frob} <- Frobs.load(name) do
      {:ok, "Frob #{name} appears to be valid!"}
    end
  end

  defp list(opts) do
    if opts[:all] do
      Services.Once.run(
        :frobs_migrate_registry_to_settings,
        &Frobs.Migrate.maybe_migrate_registry_to_settings/0
      )

      base_dir = Path.join([Settings.get_user_home(), "fnord", "tools"])

      frob_names =
        case File.ls(base_dir) do
          {:ok, entries} ->
            entries |> Enum.filter(fn entry -> File.dir?(Path.join(base_dir, entry)) end)

          _ ->
            []
        end

      global_list = Settings.Frobs.list(:global)

      project_list =
        case Settings.get_selected_project() do
          {:ok, _} -> Settings.Frobs.list(:project)
          _ -> []
        end

      frobs =
        frob_names
        |> Enum.map(fn name ->
          spec_path = Path.join([base_dir, name, "spec.json"])

          description =
            case File.read(spec_path) do
              {:ok, content} ->
                case Jason.decode(content) do
                  {:ok, %{"description" => d}} when is_binary(d) -> d
                  _ -> "No description provided"
                end

              _ ->
                "No description provided"
            end

          status =
            cond do
              name in global_list and name in project_list -> "Enabled (global and project)"
              name in global_list -> "Enabled (global)"
              name in project_list -> "Enabled (project)"
              true -> "Disabled"
            end

          """
          - Name:         #{name}
          - Description:  #{description}
          - Location:     #{Path.join([base_dir, name])}
          - Status:       #{status}
          """
        end)
        |> Enum.join("\n\n")

      if frobs == "" do
        {:ok, "No frobs found in tools directory"}
      else
        {:ok,
         """
         --------------------------------------------------------------------------------
         > Frobs
         --------------------------------------------------------------------------------
         #{frobs}
         """}
      end
    else
      global_list = Settings.Frobs.list(:global)

      project_list =
        case Settings.get_selected_project() do
          {:ok, _} -> Settings.Frobs.list(:project)
          _ -> []
        end

      frobs =
        Frobs.list()
        |> Enum.map(fn frob ->
          desc = Map.get(frob.spec, "description", "No description provided")
          enabled = Settings.Frobs.enabled?(frob.name)

          scope_info =
            if enabled do
              cond do
                frob.name in global_list and frob.name in project_list ->
                  "Enabled (global and project)"

                frob.name in global_list ->
                  "Enabled (global)"

                frob.name in project_list ->
                  "Enabled (project)"

                true ->
                  "Disabled"
              end
            else
              "Disabled"
            end

          """
          - Name:         #{frob.name}
          - Description:  #{desc}
          - Location:     #{frob.home}
          - Status:       #{scope_info}
          """
        end)
        |> Enum.join("\n\n")

      if frobs == "" do
        case Settings.get_selected_project() do
          {:ok, project} ->
            {:ok, "No frobs found for project #{project.name}"}

          _ ->
            {:ok, "No frobs found"}
        end
      else
        {:ok,
         """
         --------------------------------------------------------------------------------
         > Frobs
         --------------------------------------------------------------------------------
         #{frobs}
         """}
      end
    end
  end

  defp enable(opts) do
    name = opts[:name]

    with {:ok, scope} <- resolve_scope(opts),
         :ok <- Settings.Frobs.enable(scope, name) do
      {:ok, "Frob #{name} enabled in #{scope_label(scope)} scope."}
    end
  end

  defp disable(opts) do
    name = opts[:name]

    with {:ok, scope} <- resolve_scope(opts),
         :ok <- Settings.Frobs.disable(scope, name) do
      {:ok, "Frob #{name} disabled in #{scope_label(scope)} scope."}
    end
  end

  defp resolve_scope(opts) do
    cond do
      opts[:global] ->
        {:ok, :global}

      is_binary(opts[:project]) and byte_size(opts[:project]) > 0 ->
        {:ok, {:project, opts[:project]}}

      true ->
        case Settings.get_selected_project() do
          {:ok, _pn} -> {:ok, :project}
          _ -> raise "No project selected. Use --global or --project <name>."
        end
    end
  end

  defp scope_label(:global), do: "global"
  defp scope_label({:project, name}), do: "project: #{name}"
  defp scope_label(:project), do: "project (selected)"
end

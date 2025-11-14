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
            about: "Lists all available frobs"
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
      [:list] -> list()
      [:enable] -> enable(opts)
      [:disable] -> disable(opts)
      _ -> {:error, :invalid_subcommand}
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

  defp list() do
    frobs =
      Frobs.list()
      |> Enum.map(fn frob ->
        desc = Map.get(frob.spec, "description", "No description provided")
        enabled = Settings.Frobs.enabled?(frob.name)

        scope_info =
          if enabled do
            case Settings.get_selected_project() do
              {:ok, _} -> "Enabled (global or project)"
              _ -> "Enabled (global)"
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

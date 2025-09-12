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
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(opts, subcommands, _unknown) do
    with {:ok, msg} <- call_subcommand(subcommands, opts) do
      UI.puts(msg)
    else
      {:error, :invalid_subcommand} ->
        UI.fatal("Invalid subcommand. Use `fnord help frobs` for available commands.")

      {:error, reason} ->
        UI.fatal("Error creating frob: #{reason}")
    end
  end

  defp call_subcommand(subcommands, opts) do
    case subcommands do
      [:create] -> create(opts)
      [:check] -> check(opts)
      [:list] -> list()
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
       - Registry: `#{frob.home}/registry.json`
       - Spec:     `#{frob.home}/spec.json`
       - Main:     `#{frob.home}/main`
       --------------------------------------------------------------------------------
       > Tips
       --------------------------------------------------------------------------------
       - Edit `main` to implement your integration.
       - Update the spec in `spec.json` to define the frob's interface and parameters.
       - Register your frob globally or for specific projects in `registry.json`.

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
    with {:ok, project} <- Store.get_project() do
      frobs =
        Frobs.list()
        |> Enum.map(fn frob ->
          desc = Map.get(frob.spec, "description", "No description provided")
          is_global = frob.registry["global"] || false
          projects = frob.registry["projects"] || []

          """
          - Name:         #{frob.name}
          - Description:  #{desc}
          - Location:     #{frob.home}
          - Global:       #{is_global}
          - Projects:     #{inspect(projects)}
          """
        end)
        |> Enum.join("\n\n")

      cond do
        frobs == "" && project ->
          {:ok, "No frobs found for project #{project}"}

        frobs == "" ->
          {:ok, "No frobs found"}

        true ->
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
end

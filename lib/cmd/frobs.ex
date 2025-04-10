defmodule Cmd.Frobs do
  @behaviour Cmd

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
      IO.puts(msg)
    else
      {:error, reason} ->
        IO.puts(:stderr, "Error creating frob: #{reason}")
        System.halt(1)
    end
  end

  defp call_subcommand(subcommands, opts) do
    case subcommands do
      [:create] -> create(opts)
      [:check] -> check(opts)
      [:list] -> list(opts)
      _ -> {:error, :implement_me}
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

  defp list(_) do
    {:ok,
     Frobs.list()
     |> Enum.map(fn frob ->
       desc = Map.get(frob.spec, "description", "No description provided")
       "#{frob.name} - #{desc}"
     end)
     |> Enum.join("\n")}
  end
end

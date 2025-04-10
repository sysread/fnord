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
          spec: [
            name: "spec",
            about: "Displays frob a frob's spec",
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
    case subcommands do
      [:create] -> create(opts)
      _ -> IO.puts("implement me")
    end
  end

  defp create(%{name: name}) do
    with {:ok, frob} <- Frobs.create(name) do
      IO.puts("""
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
      - Fnord communicates run-time information to the frob via environment variables:
          - FNORD_PROJECT:    The name of the currently selected project
          - FNORD_CONFIG:     JSON object of project config (see `$HOME/.fnord/settings.json`)
          - FNORD_ARGS_JSON:  JSON object of LLM-provided arguments (defined in your spec)
      """)
    else
      {:error, reason} ->
        IO.puts(:stderr, "Error creating frob: #{reason}")
        System.halt(1)
    end
  end
end

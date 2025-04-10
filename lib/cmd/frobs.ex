defmodule Cmd.Frobs do
  @behaviour Cmd

  @impl Cmd
  def spec do
    [
      frobs: [
        name: "frobs",
        about: "Manages external tool call integrations (frobs)",
        subcommands: [
          new: [
            name: "new",
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
          list: [
            name: "list",
            about: "Lists all available frobs"
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(_opts, _unkown) do
    UI.info("implement me")
  end
end

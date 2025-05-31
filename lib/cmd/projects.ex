defmodule Cmd.Projects do
  @behaviour Cmd

  @impl Cmd
  def spec() do
    [
      projects: [
        name: "projects",
        about: "Lists all projects",
        options: []
      ]
    ]
  end

  @impl Cmd
  def run(_opts, _subcommands, _unknown) do
    Settings.new()
    |> Settings.list_projects()
    |> Enum.each(&IO.puts/1)
  end
end

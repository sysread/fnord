defmodule Cmd.Prime do
  @primer_prompt """
  Please provide an overview of the current project. Include the following information:
  - Project name
  - Project description
  - What are the main features of the project?
  - What each application does (or what the main app does, if not a multi-app project)
  - Which technologies are used in the project?
  - How is the project organized?
  - How is application code and business logic organized?
  - What are the major components of the project?
  - How do those components interact?
  - Identify common coding and testing conventions
  - Identify the location of any configuration, documentation, and CI/CD workflows, if present

  If there are any prior research notes, investigate each fact and determine if it is still valid.
  """

  @behaviour Cmd

  @impl Cmd
  def requires_project?(), do: true

  @impl Cmd
  def spec do
    [
      prime: [
        name: "prime",
        about: "Prime fnord's research notes with basic information about the project",
        options: [
          project: Cmd.project_arg()
        ]
      ]
    ]
  end

  @impl Cmd
  def run(opts, subcommands, unknown) do
    opts
    |> Map.put(:rounds, 3)
    |> Map.put(:question, @primer_prompt)
    |> Cmd.Ask.run(subcommands, unknown)
  end
end

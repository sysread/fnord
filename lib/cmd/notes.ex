defmodule Cmd.Notes do
  @behaviour Cmd

  @impl Cmd
  def spec() do
    [
      notes: [
        name: "notes",
        about: "List facts about the project inferred from prior research",
        options: [
          project: [
            value_name: "PROJECT",
            long: "--project",
            short: "-p",
            help: "Project name",
            required: true
          ]
        ],
        flags: [
          reset: [
            long: "--reset",
            short: "-r",
            help: "Delete all stored notes for the project. This action is irreversible."
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(opts, _subcommands, _unknown) do
    project = Store.get_project() |> validate_project()

    opts
    |> Map.get(:reset, false)
    |> case do
      true -> reset_notes(project)
      false -> show_notes(project)
    end
  end

  defp validate_project(project) do
    if Store.Project.exists_in_store?(project) do
      project
    else
      fail("Project not found: `#{project.name}`")
    end
  end

  defp show_notes(project) do
    project.name
    |> Store.Project.Notes.read()
    |> case do
      {:ok, notes} -> IO.puts(notes)
      {:error, :no_notes} -> IO.puts(:stderr, "No notes found")
    end
  end

  defp reset_notes(project) do
    if UI.confirm(
         "Are you sure you want to delete all notes for #{project.name}? This is irreversible!",
         false
       ) do
      IO.puts("Resetting notes for `#{project.name}`:")
      Store.Project.Notes.reset(project.name)
      IO.puts("✓ Notes reset")
    else
      IO.puts("Aborted")
    end
  end

  defp fail(reason) do
    IO.puts(:stderr, "Error: #{reason}")
    exit(1)
  end
end

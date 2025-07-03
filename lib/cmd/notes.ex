defmodule Cmd.Notes do
  @behaviour Cmd

  @impl Cmd
  def requires_project?(), do: true

  @impl Cmd
  def spec() do
    [
      notes: [
        name: "notes",
        about: "List facts about the project inferred from prior research",
        flags: [
          reset: [
            long: "--reset",
            short: "-r",
            help: "Delete all stored notes for the project. This action is irreversible."
          ]
        ],
        options: [
          project: Cmd.project_arg()
        ]
      ]
    ]
  end

  @impl Cmd
  def run(opts, _subcommands, _unknown) do
    with {:ok, project} <- Store.get_project() do
      opts
      |> Map.get(:reset, false)
      |> case do
        true -> reset_notes(project)
        false -> show_notes()
      end
    else
      {:error, reason} -> fail(reason)
    end
  end

  defp show_notes() do
    with {:ok, notes} <- Store.Project.Notes.read() do
      UI.say(notes)
    else
      {:error, :no_notes} ->
        IO.puts(:stderr, "No notes found. Please run `prime` first to gather information.")
    end
  end

  defp reset_notes(project) do
    if UI.confirm(
         "Are you sure you want to delete all notes for #{project.name}? This is irreversible!",
         false
       ) do
      IO.puts("Resetting notes for `#{project.name}`:")
      Store.Project.Notes.reset()
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

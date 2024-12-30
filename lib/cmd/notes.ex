defmodule Cmd.Notes do
  def run(opts) do
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
    IO.puts("# Project notes: #{project.name}")

    project
    |> Store.Note.list_notes()
    |> case do
      [] ->
        IO.puts("No notes found")

      notes ->
        notes
        |> Enum.each(fn note ->
          with {:ok, text} <- Store.Note.read_note(note) do
            IO.puts("- `#{note.id}` #{text}")
          else
            {:error, reason} -> fail(reason)
          end
        end)
    end
  end

  defp reset_notes(project) do
    IO.puts("Resetting notes for `#{project.name}`:")

    project
    |> Store.Note.reset_project_notes()
    |> case do
      {:ok, _} -> IO.puts("✓ Notes reset")
      {:error, reason} -> fail(reason)
    end
  end

  defp fail(reason) do
    IO.puts(:stderr, "Error: #{reason}")
    exit(1)
  end
end

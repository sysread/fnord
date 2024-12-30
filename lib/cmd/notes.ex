defmodule Cmd.Notes do
  def run(_opts) do
    project = Store.get_project()

    if Store.Project.exists_in_store?(project) do
      IO.puts("Notes for the `#{project.name}` project:")

      project
      |> Store.Note.list_notes()
      |> Enum.each(fn note ->
        with {:ok, text} <- Store.Note.read_note(note) do
          IO.puts("- `#{note.id}` #{text}")
        end
      end)
    else
      IO.puts(:stderr, "Project not found: `#{project.name}`")
      exit(1)
    end
  end
end

defmodule Cmd.Summary do
  @behaviour Cmd

  @impl Cmd
  def spec do
    [
      summary: [
        name: "summary",
        about: "Retrieve the AI-generated file summary used when indexing the file",
        options: [
          project: [
            value_name: "PROJECT",
            long: "--project",
            short: "-p",
            help: "Project name",
            required: true
          ],
          file: [
            value_name: "FILE",
            long: "--file",
            short: "-f",
            help: "File to summarize",
            required: true
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(opts) do
    # Make sure that the file path is an absolute path
    file_path = Path.absname(opts.file)
    project = Store.get_project(opts.project)

    with {:ok, entry} <- get_file(project, file_path),
         {:ok, summary} <- Store.Project.Entry.read_summary(entry),
         {:ok, outline} <- Store.Project.Entry.read_outline(entry) do
      IO.puts("# File: `#{file_path}`")
      IO.puts("- Store location: `#{entry.store_path}`")

      IO.puts("----------")
      IO.puts("# Summary")
      IO.puts(summary)

      IO.puts("----------")
      IO.puts("# Outline")
      IO.puts("```")
      IO.puts(outline)
      IO.puts("```")
    end
  end

  defp get_file(project, file_path) do
    entry = Store.Project.Entry.new_from_file_path(project, file_path)

    if Store.Project.Entry.exists_in_store?(entry) do
      {:ok, entry}
    else
      {:error, :entry_not_found}
    end
  end
end

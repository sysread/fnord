defmodule Cmd.Summary do
  @behaviour Cmd

  @impl Cmd
  def requires_project?(), do: true

  @impl Cmd
  def spec do
    [
      summary: [
        name: "summary",
        about: "Retrieve the AI-generated file summary used when indexing the file",
        options: [
          project: Cmd.project_arg(),
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
  def run(opts, _subcommands, _unknown) do
    # Make sure that the file path is an absolute path
    file_path = Path.absname(opts.file)

    with {:ok, project} <- Store.get_project(),
         {:ok, entry} <- get_file(project, file_path),
         {:ok, summary} <- Store.Project.Entry.read_summary(entry),
         {:ok, outline} <- Store.Project.Entry.read_outline(entry) do
      UI.puts("# File: `#{file_path}`")
      UI.puts("- Store location: `#{entry.store_path}`")

      UI.puts("----------")
      UI.puts("# Summary")
      UI.puts(summary)

      UI.puts("----------")
      UI.puts("# Outline")
      UI.puts("```")
      UI.puts(outline)
      UI.puts("```")
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

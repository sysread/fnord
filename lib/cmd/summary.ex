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
         {:ok, summary} <- Store.Project.Entry.read_summary(entry) do
      # Build the full markdown output and run it through UI.format, which
      # pipes through FNORD_FORMATTER if set. UI.format is a no-op on non-TTY
      # stdout or under :quiet, preserving pipe/redirect behavior.
      output =
        """
        # File: `#{file_path}`
        - Store location: `#{entry.store_path}`

        ----------

        # Summary
        #{summary}
        """

      UI.puts(UI.format(output))
    else
      {:error, :project_not_set} = err ->
        UI.error("No project selected; use --project or run in a project directory.")
        err

      {:error, :entry_not_found} = err ->
        UI.error("File not indexed: #{file_path}")
        err

      {:error, _reason} = err ->
        UI.error("Failed to read summary", inspect(err))
        err
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

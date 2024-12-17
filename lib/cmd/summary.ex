defmodule Cmd.Summary do
  @moduledoc """
  This module provides the functionality for the `summary` sub-command.
  """

  @doc """
  Run the summary process using the given `project` and `file_path`.
  """
  def run(opts) do
    # Make sure that the file path is an absolute path
    file_path = Path.absname(opts.file)
    project = Store.get_project(opts.project)

    with {:ok, entry} <- get_file(project, file_path),
         {:ok, summary} <- Store.Entry.read_summary(entry),
         {:ok, outline} <- Store.Entry.read_outline(entry) do
      IO.puts("# File: `#{file_path}`")
      IO.puts("- Store location: `#{entry.store_path}`")

      IO.puts("----------")
      IO.puts("# Summary")
      IO.puts(summary)

      IO.puts("----------")
      IO.puts("# Outline")
      IO.puts(outline)
    end
  end

  defp get_file(project, file_path) do
    entry = Store.Entry.new_from_file_path(project, file_path)

    if Store.Entry.exists_in_store?(entry) do
      {:ok, entry}
    else
      {:error, :entry_not_found}
    end
  end
end

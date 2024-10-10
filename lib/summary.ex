defmodule Summary do
  @moduledoc """
  This module provides the functionality for the `summary` sub-command.
  """

  @doc """
  Run the summary process using the given `project` and `file_path`.
  """
  def run(opts) do
    # Make sure that the file path is an absolute path
    file_path = Path.absname(opts.file)
    store = Store.new(opts.project)

    with {:ok, summary} <- Store.get_summary(store, file_path) do
      IO.puts("# File: #{file_path}")
      IO.puts(summary)
    end
  end
end

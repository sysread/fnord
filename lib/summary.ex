defmodule Summary do
  def run(project, file_path) do
    # Make sure that the file path is an absolute path
    file_path = Path.absname(file_path)
    store = Store.new(project)

    with {:ok, summary} <- Store.get_summary(store, file_path) do
      IO.puts("# File: #{file_path}")
      IO.puts(summary)
    end
  end
end

defmodule AI.Tools.FileContents do
  @behaviour AI.Tools

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "file_contents_tool",
        description: """
        Display the contents of a file in the project.
        """,
        parameters: %{
          type: "object",
          required: ["file"],
          properties: %{
            file: %{
              type: "string",
              description: """
              The file whose contents you wish to review. It must be the
              complete path provided by the search_tool or list_files_tool.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(_agent, args) do
    with {:ok, file} <- Map.fetch(args, "file"),
         {:ok, content} <- get_file_contents(file) do
      {:ok,
       """
       [file_contents_tool] Contents of #{file}:
       ```
       #{content}
       ```
       """}
    else
      {:error, :enoent} ->
        {:error,
         """
         The requested file does not exist.
         - If the file name is correct, verify the path using the search or the file listing tool.
         - It may have been added since the most recent reindexing of the project.
         - If the file is only present in a topic branch that has not yet been merged, it may not be visible to this tool.
         """}

      {:error, reason} ->
        {:error, reason}

      error ->
        error
    end
  end

  defp get_file_contents(file) do
    project = Store.get_project()
    entry = Store.Entry.new_from_file_path(project, file)

    if Store.Entry.source_file_exists?(entry) do
      Store.Entry.read_source_file(entry)
    else
      {:error, :enoent}
    end
  end
end

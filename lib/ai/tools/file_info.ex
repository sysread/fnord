defmodule AI.Tools.FileInfo do
  @behaviour AI.Tools

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "file_info_tool",
        description: """
        Requests information about a file. Ensure that you craft your question
        to explicitly identify how you want the information presented. Nuanced
        questions with an output template yield the best results.

        This tool can be used to extract sections of code, functions,
        interfaces, definitions, or entire file contents upon request. NOTE
        that this is the most recently indexed version of the file; use
        git_show_tool to view the current or a specific historical version. Use
        file_contents tool to get the raw file contents.

        Ensure the file path matches one provided by the list_files_tool or
        search_tool to avoid enoent errors.

        This tool has access to the git_log_tool, git_show_tool,
        git_pickaxe_tool, and can use these to provide context about its
        history and differences from earlier version.
        """,
        parameters: %{
          type: "object",
          required: ["file", "question"],
          properties: %{
            file: %{
              type: "string",
              description: """
              The file to ask the question about. It must be the complete path
              provided by the search_tool or list_files_tool.
              """
            },
            question: %{
              type: "string",
              description: """
              The question to ask. For example:
              - How is X initialized in the constructor?
              - Respond with the complete code block for the function Y.
              - Trace the flow of data when function Y is called with the argument Z.
              - Does this module implement $the_interface_the_user_is_looking_for?
              - List all user-facing commands exposed by this module.
              - How can this module's public interface be used to implement X?
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(agent, args) do
    with {:ok, question} <- Map.fetch(args, "question"),
         {:ok, file} <- Map.fetch(args, "file"),
         {:ok, content} <- get_file_contents(file),
         {:ok, response} <-
           AI.Agent.FileInfo.get_response(agent.ai, %{
             file: file,
             question: question,
             content: content
           }) do
      {:ok, "[file_info_tool]\n#{response}"}
    else
      {:error, :enoent} ->
        {:error,
         """
         The requested file does not exist.
         - If the file name is correct, verify the path using the search or the file listing tool.
         - It may have been added since the most recent reindexing of the project.
         - If the file is only present in a topic branch that has not yet been merged, it may not be visible to this tool.

         ARGS: #{inspect(args)}
         """}

      {:error, reason} ->
        {:error, reason}

      error ->
        error
    end
  end

  defp get_file_contents(file) do
    project = Store.get_project()
    entry = Store.Project.Entry.new_from_file_path(project, file)

    if Store.Project.Entry.source_file_exists?(entry) do
      Store.Project.Entry.read_source_file(entry)
    else
      {:error, :enoent}
    end
  end
end

defmodule AI.Tools.FileInfo do
  @behaviour AI.Tools

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "file_info_tool",
        description: """
        Requests specialized information about a specific file. The AI agent
        will analyze the file and answer your question as specifically as
        possible. Ensure that you craft your question to explicitly identify
        how you want the information presented. Specific questions with
        explicit output instructions typically yield the best results. It is
        recommended that you ask only a *single* question per tool call to
        ensure the most complete answer, and make multiple calls concurrently
        if you have multiple questions about a given file.

        This tool has access to the git_show_tool and git_pickaxe_tool, and
        can use these to provide context about its history and differences from
        earlier version.
        """,
        parameters: %{
          type: "object",
          required: ["file", "question"],
          properties: %{
            file: %{
              type: "string",
              description: """
              The file to ask the question about. It must be the absolute path
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
         {:ok, contents} <- File.read(file),
         {:ok, response} <- AI.Agent.FileInfo.get_response(agent.ai, file, question, contents) do
      {:ok, "[file_info_tool]\n#{response}"}
    end
  end
end

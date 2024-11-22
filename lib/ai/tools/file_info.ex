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

        Note that this tool only has access to the current version of the file.
        It cannot read historical versions of the file or access the file's
        version control history. Provide any context related to that in your
        question as appropriate.
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
         {:ok, file} <- Map.fetch(args, "file") do
      with {:ok, contents} <- File.read(file) do
        agent.ai
        |> AI.Agent.FileInfo.new(question, contents)
        |> AI.Agent.FileInfo.get_summary()
        |> case do
          {:ok, info} -> {:ok, "[file_info_tool]\n#{info}"}
          {:error, reason} -> {:error, reason}
        end
      else
        # File read errors are not fatal, and should be communicated to the
        # Answers Agent.
        {:error, reason} -> {:ok, reason |> :file.format_error() |> to_string()}
      end
    end
  end
end

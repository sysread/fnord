defmodule AI.Tools.FileInfo do
  @behaviour AI.Tools

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "file_info_tool",
        description: "ask an AI agent a question about an individual file's contents",
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
        status_id = Tui.add_step("Considering #{file}", question)

        agent.ai
        |> AI.Agent.FileInfo.new(question, contents)
        |> AI.Agent.FileInfo.get_summary()
        |> case do
          {:ok, info} ->
            Tui.finish_step(status_id, :ok)
            {:ok, "[file_info_tool]\n#{info}"}

          {:error, reason} ->
            Tui.finish_step(status_id, :error, reason)
            {:error, reason}
        end
      else
        # File read errors are not fatal, and should be communicated to the
        # Answers Agent.
        {:error, reason} -> {:ok, reason |> :file.format_error() |> to_string()}
      end
    end
  end
end

defmodule AI.Tools.FileInfo do
  require Logger

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
              description: "The question to ask."
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
        Logger.info("[file info] considering #{file}: #{question}")

        agent.ai
        |> AI.Agent.FileInfo.new(question, contents)
        |> AI.Agent.FileInfo.get_summary()
        |> case do
          {:ok, info} ->
            Logger.debug("[file info]: #{file} - #{question}\n#{info}")
            {:ok, "[file_info_tool]\n#{info}"}

          {:error, reason} ->
            Logger.error("[file info] error getting file info on #{file}: #{reason}")
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

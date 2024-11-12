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
         {:ok, file} <- Map.fetch(args, "file"),
         {:ok, contents} <- File.read(file) do
      status_msg =
        Owl.Data.tag(
          [
            "Considering ",
            Owl.Data.tag(file, :yellow)
          ],
          :default_color
        )

      status_id = UI.add_status(status_msg, question)

      AI.Agent.FileInfo.new(agent.ai, question, contents)
      |> AI.Agent.FileInfo.get_summary()
      |> case do
        {:ok, info} ->
          UI.complete_status(status_id, :ok)
          {:ok, info}

        {:error, reason} ->
          UI.complete_status(status_id, :error, reason)
          {:error, reason}
      end
    end
  end
end

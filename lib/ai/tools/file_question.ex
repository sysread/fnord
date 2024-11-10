defmodule AI.Tools.FileQuestion do
  @behaviour AI.Tools

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "file_question_tool",
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
      Ask.update_status("Assistant asking \"#{question}\" about file #{file}")

      AI.Agent.FileQuestion.new(agent.ai, question, contents)
      |> AI.Agent.FileQuestion.get_summary()
    end
  end
end

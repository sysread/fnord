defmodule AI.Tools.File.Spelunker do
  @behaviour AI.Tools

  @impl AI.Tools
  def ui_note_on_request(_args), do: nil

  @impl AI.Tools
  def ui_note_on_result(_args, _result), do: nil

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "file_spelunker_tool",
        description: """
        Instructs an LLM to trace execution paths through the code to identify
        callers, callees, paths, and conditional logic affecting them. It can
        answer questions about the structure of the code and traverse multiple
        files to provide a call tree.
        """,
        strict: true,
        parameters: %{
          additionalProperties: false,
          type: "object",
          required: ["symbol", "start_file", "question"],
          properties: %{
            symbol: %{
              type: "string",
              description: """
              A symbol to use as an anchor reference to start the search from.
              For example, a function name, variable, or value.
              """
            },
            start_file: %{
              type: "string",
              description: "A file path from the file_list_tool or file_search_tool."
            },
            question: %{
              type: "string",
              description: """
              A prompt for the spelunker agent to respond to. For example:
              - Identify all functions called by <symbol>
              - Identify all functions that call <symbol>
              - Starting from <start file>:<symbol>, trace logic to <end file>:<symbol>
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(agent, args) do
    with {:ok, symbol} <- Map.fetch(args, "symbol"),
         {:ok, start_file} <- Map.fetch(args, "start_file"),
         {:ok, question} <- Map.fetch(args, "question") do
      AI.Agent.Spelunker.get_response(agent.ai, %{
        symbol: symbol,
        start_file: start_file,
        question: question
      })
    end
  end
end

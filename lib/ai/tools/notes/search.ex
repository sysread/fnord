defmodule AI.Tools.Notes.Search do
  @behaviour AI.Tools

  @impl AI.Tools
  def ui_note_on_request(%{"query" => query}) do
    {"Searching the archives for prior research", "#{query}"}
  end

  @impl AI.Tools
  def ui_note_on_result(%{"query" => query}, result) do
    {"Prior research identified from the archives", "#{query}\n#{result}"}
  end

  @impl AI.Tools
  def read_args(%{"query" => query}), do: {:ok, %{"query" => query}}
  def read_args(_args), do: AI.Tools.required_arg_error("query")

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "notes_search_tool",
        description: """
        Every time you perform research, you have saved notes and hints to
        yourself. Use this tool to search your prior notes to see if you've
        already gained some past insight into the user's question.
        """,
        strict: true,
        parameters: %{
          additionalProperties: false,
          type: "object",
          required: ["query"],
          properties: %{
            query: %{
              type: "string",
              description: """
              Request information from the Archivist Agent related to the
              user's needs and the research task being performed.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(completion, args) do
    with {:ok, query} <- Map.fetch(args, "query") do
      AI.Agent.Archivist.get_response(completion.ai, %{query: query})
    end
  end
end

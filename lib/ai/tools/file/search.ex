defmodule AI.Tools.File.Search do
  @max_search_results 5

  @behaviour AI.Tools

  @impl AI.Tools
  def ui_note_on_request(args), do: {"Searching", args["query"]}

  @impl AI.Tools
  def ui_note_on_result(_args, _result), do: nil

  @impl AI.Tools
  def read_args(%{"query" => query}), do: {:ok, %{"query" => query}}

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "file_search_tool",
        description: """
        The search tool implements a robust semantic search to find project
        files matching your query input. This tool does NOT have access to
        historical data or commit messages. It only searches the most recently
        indexed version of the project.
        """,
        strict: true,
        parameters: %{
          additionalProperties: false,
          type: "object",
          required: ["query"],
          properties: %{
            query: %{
              type: "string",
              description: "The search query string."
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(completion, args) do
    opts = Map.get(completion, :opts, %{})

    with {:ok, query} <- Map.fetch(args, "query"),
         {:ok, matches} <- search(query, opts) do
      matches
      |> Enum.map(fn {file, score, data} ->
        """
        # `#{file}` (cosine similarity: #{score})
        #{data["summary"]}
        """
      end)
      |> Enum.join("\n-----\n")
      |> then(fn res -> {:ok, "[search_tool]\n#{res}"} end)
    end
  end

  # -----------------------------------------------------------------------------
  # Searches the database for matches to the search query. Returns a list of
  # `{file, score, data}` tuples.
  # -----------------------------------------------------------------------------
  defp search(query, opts) do
    opts
    |> Map.put(:detail, true)
    |> Map.put(:limit, @max_search_results)
    |> Map.put(:query, query)
    |> Search.new()
    |> Search.get_results()
    |> Enum.map(fn {entry, score, data} ->
      {entry.rel_path, score, data}
    end)
    |> then(&{:ok, &1})
  end
end

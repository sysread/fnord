defmodule AI.Tools.Search do
  @max_search_results 5

  @behaviour AI.Tools

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "search_tool",
        description: """
        The search tool uses a semantic search to find files that match your
        query input. The entire project has been indexed using a deep vector
        space, with each file being pre-processed by an AI to summarize its
        contents and behaviors, and to generate a list of symbols in the file.
        This allows you to craft your query using phrases likely to match the
        description of the code's behavior, rather than just the code itself.
        """,
        parameters: %{
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
  def call(agent, args) do
    with {:ok, query} <- Map.fetch(args, "query") do
      status_id = Tui.add_step("Searching", query)

      with {:ok, matches} <- search(query, agent.opts) do
        Tui.finish_step(status_id, :ok)

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
  end

  # -----------------------------------------------------------------------------
  # Searches the database for matches to the search query. Returns a list of
  # `{file, score, data}` tuples.
  # -----------------------------------------------------------------------------
  defp search(query, opts) do
    opts
    |> Map.put(:concurrency, opts.concurrency)
    |> Map.put(:detail, true)
    |> Map.put(:limit, @max_search_results)
    |> Map.put(:query, query)
    |> Search.new()
    |> Search.get_results()
    |> then(&{:ok, &1})
  end
end

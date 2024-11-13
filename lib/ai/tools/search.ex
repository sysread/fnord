defmodule AI.Tools.Search do
  require Logger

  @max_search_results 5

  @behaviour AI.Tools

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "search_tool",
        description: "searches for matching files and their contents",
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
      Logger.info("[search] searching: #{query}")

      with {:ok, matches} <- search(query, agent.opts) do
        files =
          matches
          |> Enum.map(fn {file, score, _} -> "  - #{file} (#{score})" end)
          |> Enum.join("\n")

        Logger.debug("[search] found:\n#{files}")

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

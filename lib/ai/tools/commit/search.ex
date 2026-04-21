defmodule AI.Tools.Commit.Search do
  @behaviour AI.Tools

  @max_search_results 25

  @impl AI.Tools
  def async?, do: true

  @impl AI.Tools
  def is_available?(), do: AI.Tools.has_indexed_project()

  @impl AI.Tools
  def ui_note_on_request(args), do: {"Commit search", args["query"]}

  @impl AI.Tools
  def ui_note_on_result(%{"query" => query}, result) do
    re = ~r/Commit search found (\d+) matching commits in (\d+) ms:/

    case Regex.run(re, result) do
      [_, count_str, took_ms] ->
        count = String.to_integer(count_str)
        {"Commit search", "#{query} -> #{count} commit matches in #{took_ms} ms"}

      _ ->
        {"Commit search", "#{query} -> #{result}"}
    end
  end

  @impl AI.Tools
  def tool_call_failure_message(_args, _reason), do: :default

  @impl AI.Tools
  def read_args(%{"query" => query} = args) do
    limit = Map.get(args, "limit", @max_search_results)

    {:ok,
     %{
       "query" => query,
       "limit" => normalize_limit(limit)
     }}
  end

  def read_args(_), do: AI.Tools.required_arg_error("query")

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "commit_search_tool",
        description: "Semantic search over indexed git commits.",
        parameters: %{
          additionalProperties: false,
          type: "object",
          required: ["query"],
          properties: %{
            query: %{
              type: "string",
              description: "Natural language query to match against commit embeddings."
            },
            limit: %{
              type: "integer",
              description:
                "Maximum number of results to return (default: #{@max_search_results}).",
              minimum: 1,
              maximum: 100
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(%{"query" => query, "limit" => limit}) do
    start_time = DateTime.utc_now()

    with {:ok, matches} <- do_search(query, limit),
         took_ms = DateTime.diff(DateTime.utc_now(), start_time, :millisecond),
         {:ok, index_state_msg} <- index_state() do
      {:ok, build_response(matches, took_ms, index_state_msg)}
    end
  end

  # --- internals ---

  defp normalize_limit(limit) when is_integer(limit) and limit > 0 and limit <= 100, do: limit
  defp normalize_limit(_), do: @max_search_results

  defp build_response(matches, took_ms, index_state_msg) do
    header = "[commit_search_tool]"

    body =
      matches
      |> Enum.map(&format_entry/1)
      |> Enum.join("\n-----\n")
      |> then(fn body ->
        """
        Commit search found #{length(matches)} matching commits in #{took_ms} ms:
        -----
        #{body}
        """
      end)

    [header, body, "-----", index_state_msg]
    |> Enum.join("\n")
  end

  defp format_entry({sha, score, metadata}) do
    subject = Map.get(metadata, "subject") || "(no subject)"
    author = Map.get(metadata, "author") || "(unknown)"
    time = Map.get(metadata, "committed_at") || ""

    """
    # #{sha} (cosine similarity: #{score})
    - subject: #{subject}
    - author: #{author}
    - committed_at: #{time}
    """
  end

  defp index_state() do
    with {:ok, project} <- Store.get_project() do
      %{new: new, stale: stale, deleted: deleted} =
        Store.Project.CommitIndex.index_status(project)

      msg = """
      The results of this search may be affected by the state of the commit index.

      The current commit index state is:
      - New commits (not yet embedded): #{length(new)}
      - Stale commits (outdated index): #{length(stale)}
      - Deleted commits (indexed but missing from repo): #{length(deleted)}

      If you are seeing unexpected search results, re-run `fnord index`.
      """

      {:ok, msg}
    end
  end

  defp do_search(query, limit) do
    %{"query" => query, "limit" => limit}
    |> Search.Commits.new()
    |> Search.Commits.get_results()
  end
end

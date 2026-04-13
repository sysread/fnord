defmodule AI.Tools.Commit.Search do
  @behaviour AI.Tools

  @max_search_results 25

  @impl AI.Tools
  def async?, do: true

  @impl AI.Tools
  def is_available?() do
    GitCli.is_git_repo?()
  end

  @impl AI.Tools
  def ui_note_on_request(args), do: {"Commit search", args["query"]}

  @impl AI.Tools
  def ui_note_on_result(%{"query" => query}, result) do
    re = ~r/Semantic search found (\d+) matching commits in (\d+) ms:/

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
  def read_args(%{"query" => query}), do: {:ok, %{"query" => query}}

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "commit_search_tool",
        description: "Semantic search over indexed git commits (git repository required)",
        parameters: %{
          additionalProperties: false,
          type: "object",
          required: ["query"],
          properties: %{
            query: %{
              type: "string",
              description: "A natural language query to search commit semantics"
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(args) do
    with {:ok, query} <- Map.fetch(args, "query"),
         {:ok, project} <- Store.get_project(),
         start_time = DateTime.utc_now(),
         {:ok, matches} <- Search.Commits.search(project, query, limit: @max_search_results),
         took_ms = DateTime.diff(DateTime.utc_now(), start_time, :millisecond) do
      {:ok, build_response(matches, took_ms)}
    end
  end

  defp build_response(matches, took_ms) do
    header = "[search_tool]"

    body =
      matches
      |> Enum.map(&format_entry/1)
      |> Enum.join("\n-----\n")
      |> then(fn body ->
        """
        Semantic search found #{length(matches)} matching commits in #{took_ms} ms:
        -----
        #{body}
        """
      end)

    [header, body]
    |> Enum.join("\n")
  end

  defp format_entry(%{
         sha: sha,
         subject: subject,
         author: author,
         committed_at: committed_at,
         score: score
       }) do
    """
    - #{sha} (score: #{Float.round(score, 4)})
      subject: #{subject}
      author: #{author}
      committed_at: #{committed_at}
    """
  end
end

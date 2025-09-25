defmodule AI.Tools.File.Search do
  @max_search_results 25

  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: true

  @doc """
  This tool requires that the project has been indexed to use. If the project
  has not been indexed, the tool should not be made available.
  """
  @impl AI.Tools
  def is_available?(), do: AI.Tools.has_indexed_project()

  @impl AI.Tools
  def ui_note_on_request(args), do: {"Semantic search", args["query"]}

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
        files matching your query input. Each file in the search index was
        primed for semantic search using an LLM to generate contextual content
        related to the file contents, allowing for improved fuzzy searches.

        This tool is ideal when you need to find files related to a topic but
        do not have an exact string to match. For example, you can search for
        "user authentication" to find files related to user login, regardless
        of whether they contain that exact phrase.

        If you are looking for an exact pattern, your best bet is to use grep
        or a similar command via the `shell_tool`. This tool is optimized for
        identifying content when you are not sure what you are looking for. For
        example, you can search for "user authentication" or "ETL pipeline" or
        "feature flags" to find files related to those topics, even if the
        exact terms do not appear in the file names or contents.

        Note that this tool does not have access to historical data or commit
        messages. It only searches the most recently indexed version of the
        project.
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
  def call(args) do
    with {:ok, query} <- Map.fetch(args, "query"),
         {:ok, matches} <- search(query),
         {:ok, index_state_msg} <- index_state() do
      {:ok, build_response(matches, index_state_msg)}
    end
  end

  # Build the complete tool response by formatting matches and the index state banner.
  defp build_response(matches, index_state_msg) do
    header = "[search_tool]"
    body = matches |> Enum.map(&format_entry/1) |> Enum.join("\n-----\n")

    [header, body, "-----", index_state_msg]
    |> Enum.join("\n")
  end

  # Format a single search result entry as markdown with file, similarity, and summary.
  defp format_entry({file, score, data}) do
    """
    # `#{file}` (cosine similarity: #{score})
    #{data["summary"]}
    """
  end

  # -----------------------------------------------------------------------------
  # Returns the current state of the project index, including new, stale, and
  # deleted files.
  # -----------------------------------------------------------------------------
  defp index_state do
    with {:ok, project} <- Store.get_project() do
      %{new: new, stale: stale, deleted: deleted} = Store.Project.index_status(project)

      msg =
        """
        The results of this search may be affected by the state of the project index.

        The current index state is:
        - New files (not yet indexed): #{length(new)}
        - Stale files (outdated index): #{length(stale)}
        - Deleted files (indexed but deleted in project): #{length(deleted)}

        If you are seeing unexpected search results, try reindexing with the `file_reindex_tool` tool.
        """

      {:ok, msg}
    end
  end

  # -----------------------------------------------------------------------------
  # Searches the database for matches to the search query. Returns a list of
  # `{file, score, data}` tuples.
  # -----------------------------------------------------------------------------
  defp search(query) do
    %{
      detail: true,
      limit: @max_search_results,
      query: query
    }
    |> Search.new()
    |> Search.get_results()
    |> case do
      {:ok, results} ->
        results
        |> Enum.map(fn {entry, score, data} ->
          {entry.rel_path, score, data}
        end)
        |> then(&{:ok, &1})

      {:error, reason} ->
        {:error, reason}
    end
  end
end

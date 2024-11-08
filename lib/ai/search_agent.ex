defmodule AI.SearchAgent do
  @moduledoc """
  When `AI.AnswersAgent` receives a tool call request from the assistant, it
  will use this module to perform the search using `Search`. The contents of
  the files matched are then sent to the `AI.RelevantFileSections` module,
  which will identify the aspects of the file that are relevant to the user's
  query as well as the `AI.AnswersAgent`' search criteria.
  """

  defstruct [
    :ai,
    :opts,
    :user_query,
    :search_query
  ]

  def new(ai, user_query, search_query, opts) do
    %AI.SearchAgent{
      ai: ai,
      opts: opts,
      user_query: user_query,
      search_query: search_query
    }
  end

  @doc """
  Performs a concurrent search on behalf of the `AI.AnswersAgent` agent. It
  uses the `Search` module to search the database for matches to the search
  query. Then, it concurrently feeds the contents of each matched file to the
  `AI.RelevantFileSections` agent, which will identify the relevant sections of
  the file.
  """
  def search(agent) do
    with {:ok, queue} <- get_queue(agent),
         {:ok, matches} <- get_matches(agent),
         {:ok, results} <- process_matches(queue, matches) do
      {:ok, results}
    end
  end

  # -----------------------------------------------------------------------------
  # Starts and returns a process pool using the `Queue` module. It is
  # configured to retrieve the relevant sections of the file using the
  # `AI.RelevantFileSections` agent which match the user's query and the
  # `AI.AnswersAgent` agent's search criteria.
  # -----------------------------------------------------------------------------
  defp get_queue(agent) do
    Queue.start_link(agent.opts.concurrency, fn {file, score, data} ->
      get_entry_agent_response(agent, {file, score, data})
    end)
  end

  defp process_matches(queue, matches) do
    matches
    |> Queue.map(queue)
    |> Enum.reduce([], fn
      {:ok, result}, acc ->
        [result | acc]

      {:error, reason}, acc ->
        IO.inspect(reason, label: "search agent error")
        acc
    end)
    |> then(&{:ok, &1})
  end

  # -----------------------------------------------------------------------------
  # Reads the file contents, get the relevant sections using the
  # `AI.RelevantFileSections` agent, and returns a formatted string response
  # that includes the file and match information, the summary of the file (that
  # was generated when the file was indexed by the `AI.Summarizer` agent), and
  # the relevant sections of the file that were identified by the
  # `AI.RelevantFileSections` agent.
  # -----------------------------------------------------------------------------
  defp get_entry_agent_response(agent, {file, score, data}) do
    with {:ok, file_content} <- File.read(file),
         {:ok, sections} <- get_relevant_sections(agent, file_content) do
      result = """
      -----
      # File: #{file} | Score: #{score}

      ## Summary
      #{data["summary"]}

      ## Relevant Sections
      #{sections}
      """

      {:ok, result}
    end
  end

  # -----------------------------------------------------------------------------
  # Uses the `AI.RelevantFileSections` agent to identify the sections of the
  # file that are relevant to the user's and `AI.AnswersAgent` agent's queries.
  # -----------------------------------------------------------------------------
  defp get_relevant_sections(agent, file_content) do
    AI.RelevantFileSections.new(
      agent.ai,
      agent.user_query,
      agent.search_query,
      file_content
    )
    |> AI.RelevantFileSections.get_summary()
  end

  # -----------------------------------------------------------------------------
  # Searches the database for matches to the search query. Returns a list of
  # `{file, score, data}` tuples.
  # -----------------------------------------------------------------------------
  defp get_matches(agent) do
    agent.opts
    |> Map.put(:concurrency, agent.opts.concurrency)
    |> Map.put(:detail, true)
    |> Map.put(:limit, 10)
    |> Map.put(:query, agent.search_query)
    |> Search.new()
    |> Search.get_results()
    |> then(&{:ok, &1})
  end
end

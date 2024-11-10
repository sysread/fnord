defmodule AI.Agent.Search do
  @moduledoc """
  When `AI.Agent.Answers` receives a tool call request from the assistant, it
  will use this module to perform the search using `Search`. The contents of
  the files matched are then sent to the `AI.Agent.RelevantFileSections`
  module, which will identify the aspects of the file that are relevant to the
  user's query as well as the `AI.Agent.Answers`' search criteria.

  This is not a true AI agent, but rather a module that performs the search and
  coordinates the use of the `AI.Agent.RelevantFileSections` agent to identify
  the relevant sections of each of the file results.
  """

  defstruct [
    :ai,
    :opts,
    :user_query,
    :search_query
  ]

  @max_search_results 5
  @max_retries 3

  def new(ai, user_query, search_query, opts) do
    %AI.Agent.Search{
      ai: ai,
      opts: opts,
      user_query: user_query,
      search_query: search_query
    }
  end

  @doc """
  Performs a concurrent search on behalf of the `AI.Agent.Answers` agent. It
  uses the `Search` module to search the database for matches to the search
  query. Then, it concurrently feeds the contents of each matched file to the
  `AI.Agent.RelevantFileSections` agent, which will identify the relevant
  sections of the file.
  """
  def search(agent) do
    with {:ok, matches} <- get_matches(agent),
         {:ok, queue} <- get_queue(agent),
         {:ok, results} <- process_matches(queue, matches) do
      Queue.shutdown(queue)
      Queue.join(queue)
      {:ok, results}
    end
  end

  # -----------------------------------------------------------------------------
  # Starts and returns a process pool using the `Queue` module. It is
  # configured to retrieve the relevant sections of the file using the
  # `AI.Agent.RelevantFileSections` agent which match the user's query and the
  # `AI.Agent.Answers` agent's search criteria.
  # -----------------------------------------------------------------------------
  defp get_queue(agent) do
    Queue.start_link(agent.opts.concurrency, fn {file, score, data} ->
      get_entry_agent_response(agent, {file, score, data})
    end)
  end

  # -----------------------------------------------------------------------------
  # Processes the matches returned by the `Search` module. It then uses the
  # `Queue` module to concurrently request that the
  # `AI.Agent.RelevantFileSections` agent identify the relevant sections of the
  # file that match the user's query and the `AI.Agent.Answers` agent's search
  # criteria.
  # -----------------------------------------------------------------------------
  defp process_matches(queue, matches) do
    with_retries(@max_retries, fn ->
      matches
      |> Queue.map(queue)
      |> Enum.reduce([], fn
        {:ok, result}, acc ->
          [result | acc]

        {:error, reason}, acc ->
          IO.inspect(:stderr, reason, label: "search agent warning")
          acc
      end)
      |> then(&{:ok, &1})
    end)
  end

  defp with_retries(max_attempts, fun) do
    with_retries(max_attempts, 1, fun)
  end

  defp with_retries(max_attempts, current_attempt, fun) do
    if current_attempt > max_attempts do
      {:error, :max_attempts_reached}
    else
      try do
        fun.()
      rescue
        error ->
          IO.inspect(:stderr, error,
            label: "search agent error (attempt #{current_attempt}/#{max_attempts})"
          )

          Process.sleep(200)
          with_retries(max_attempts, current_attempt + 1, fun)
      end
    end
  end

  # -----------------------------------------------------------------------------
  # Reads the file contents, get the relevant sections using the
  # `AI.Agent.RelevantFileSections` agent, and returns a formatted string
  # response that includes the file and match information, the summary of the
  # file (that was generated when the file was indexed by the `AI.Summarizer`
  # agent), and the relevant sections of the file that were identified by the
  # `AI.Agent.RelevantFileSections` agent.
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
  # file that are relevant to the user's and `AI.Agent.Answers` agent's queries.
  # -----------------------------------------------------------------------------
  defp get_relevant_sections(agent, file_content) do
    AI.Agent.RelevantFileSections.new(
      agent.ai,
      agent.user_query,
      agent.search_query,
      file_content
    )
    |> AI.Agent.RelevantFileSections.get_summary()
  end

  # -----------------------------------------------------------------------------
  # Searches the database for matches to the search query. Returns a list of
  # `{file, score, data}` tuples.
  # -----------------------------------------------------------------------------
  defp get_matches(agent) do
    agent.opts
    |> Map.put(:concurrency, agent.opts.concurrency)
    |> Map.put(:detail, true)
    |> Map.put(:limit, @max_search_results)
    |> Map.put(:query, agent.search_query)
    |> Search.new()
    |> Search.get_results()
    |> then(&{:ok, &1})
  end
end

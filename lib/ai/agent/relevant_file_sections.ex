defmodule AI.Agent.RelevantFileSections do
  defstruct [
    :ai,
    :splitter,
    :summary,
    :user_query,
    :search_query
  ]

  @model "gpt-4o-mini"

  @max_tokens 128_000

  @chunk_prompt """
  You are processing file chunks in sequence, each paired with an "accumulator"
  string to update, with each input in the following format:

  ```
  # User Query
  $user_query

  # Search Query
  $search_query

  # Accumulated Notes
  $your_accumulated_notes

  -----
  $current_file_chunk
  ```

  Guidelines for updating the accumulator:

  1. Add Relevant Content: Append relevant info from the current chunk, without overwriting existing content
  2. Continuity: Build on the existing summary, preserving its structure
  3. Handle Incompletes: If a chunk is incomplete, mark it (e.g., `<partial>`) to complete later
  4. Consistent Format: Append new content in list format under "Accumulated Summary.
  5. Avoid Redundancy: Do not duplicate existing content unless it adds clarity
  6. For Code: Quote relevant sections briefly, including function context
  7. For Docs/Notes: Cite key facts concisely
  7. Assist Search Agent: Optimize the accumulator to provide the most relevant, complete notes to help the search agent answer the user's question

  Respond ONLY with the `Accumulated Notes` section, formatted as a list,
  including your updates from the current chunk.
  """

  @final_prompt """
  You have processed a file in chunks and have collected a list of notes about
  the file's contents and their relevance to the user's query and the search
  query used by the Search Agent that found the file. Please review the notes
  and reorganize them as needed to provide a coherent and concise summary of
  the relevant sections of the file.

  Your input will be in the format:

  ```
  # User Query
  $user_query

  # Search Query
  $search_query

  # Accumulated Notes
  $your_accumulated_notes

  -----
  ```

  Please respond ONLY with your reorganized `Accumulated Notes` section,
  formatted as a list.

  """

  def new(ai, user_query, search_query, file_content) do
    %AI.Agent.RelevantFileSections{
      ai: ai,
      splitter: AI.TokenSplitter.new(file_content, @max_tokens),
      summary: "",
      user_query: user_query,
      search_query: search_query
    }
  end

  def get_summary(agent) do
    reduce(agent)
  end

  defp reduce(%{splitter: %{done: true}} = agent) do
    finish(agent)
  end

  defp reduce(%{splitter: %{done: false}} = agent) do
    with {:ok, agent} <- process_chunk(agent) do
      reduce(agent)
    end
  end

  defp finish(agent) do
    prompt = get_prompt(agent)

    OpenaiEx.Chat.Completions.create(
      agent.ai.client,
      OpenaiEx.Chat.Completions.new(
        model: @model,
        messages: [
          OpenaiEx.ChatMessage.system(@final_prompt),
          OpenaiEx.ChatMessage.user(prompt)
        ]
      )
    )
    |> case do
      {:ok, %{"choices" => [%{"message" => %{"content" => summary}}]}} -> {:ok, summary}
      {:error, reason} -> {:error, reason}
      response -> {:error, "unexpected response: #{inspect(response)}"}
    end
  end

  defp process_chunk(agent) do
    prompt = get_prompt(agent)

    {chunk, splitter} = AI.TokenSplitter.next_chunk(agent.splitter, prompt)

    agent = %{agent | splitter: splitter}
    message = prompt <> chunk

    OpenaiEx.Chat.Completions.create(
      agent.ai.client,
      OpenaiEx.Chat.Completions.new(
        model: @model,
        messages: [
          OpenaiEx.ChatMessage.system(@chunk_prompt),
          OpenaiEx.ChatMessage.user(message)
        ]
      )
    )
    |> case do
      {:ok, %{"choices" => [%{"message" => %{"content" => summary}}]}} ->
        {:ok, %AI.Agent.RelevantFileSections{agent | splitter: splitter, summary: summary}}

      {:error, reason} ->
        {:error, reason}

      response ->
        {:error, "unexpected response: #{inspect(response)}"}
    end
  end

  defp get_prompt(agent) do
    """
    # User Query
    #{agent.user_query}

    # Search Query
    #{agent.search_query}

    # Accumulated Notes
    #{agent.summary}

    -----

    """
  end
end

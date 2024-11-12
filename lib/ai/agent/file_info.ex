defmodule AI.Agent.FileInfo do
  defstruct [
    :ai,
    :question,
    :splitter,
    :summary
  ]

  @model "gpt-4o-mini"

  # It's actually 128k for this model, but this gives us a little bit of
  # wiggle room in case the tokenizer we are using falls behind.
  @max_tokens 100_000

  @chunk_prompt """
  You are an AI agent who is responsible for answering questions about a file's
  contents. The AI search agent will request specific details about a file. You
  will read through the file, one chunk at a time (when the file is larger than
  your context window), and collect notes about the file's contents that are
  relevant to the user's query.

  You are processing file chunks in sequence, each paired with an "accumulator"
  string to update, each input in the following format:

  ```
  # Question
  $question

  # Accumulated Notes
  $your_accumulated_notes

  -----
  $current_file_chunk
  ```

  Guidelines for updating the accumulator:

  1. Add Relevant Content: Add notes about the current chunk that might be relevant to the user's question
  2. Continuity: Build on the existing summary, preserving its structure
  3. Handle Incompletes: If a chunk is incomplete, mark it (e.g., `<partial>`) to complete later
  4. Consistent Format: Append new content in list format under "Accumulated Summary.
  5. Avoid Redundancy: Do not duplicate existing content unless it adds clarity
  6. For Code: Quote relevant sections briefly, including function context
  7. For Docs/Notes: Cite key facts concisely
  7. Assist Search Agent: Optimize the accumulator to provide the most relevant, complete notes to help the search agent's question

  Respond ONLY with the `Accumulated Notes` section, formatted as a list,
  including your updates from the current chunk.
  """

  @final_prompt """
  You have processed a file in chunks and have collected a list of notes about
  the file's contents and their relevance to the search agent's question.
  Please review the notes and reorganize them as needed to provide a coherent
  and concise answer to the search agent's question.

  Your input will be in the format:

  ```
  # Question
  $question

  # Accumulated Notes
  $your_accumulated_notes

  -----
  ```

  Please respond ONLY with your reorganized `Accumulated Notes` section,
  formatted as a list.
  """

  def new(ai, question, file_content) do
    %__MODULE__{
      ai: ai,
      question: question,
      splitter: AI.TokenSplitter.new(file_content, @max_tokens),
      summary: ""
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
        {:ok, %__MODULE__{agent | splitter: splitter, summary: summary}}

      {:error, reason} ->
        {:error, reason}

      response ->
        {:error, "unexpected response: #{inspect(response)}"}
    end
  end

  defp get_prompt(agent) do
    """
    # Question
    #{agent.question}

    # Accumulated Notes
    #{agent.summary}

    -----

    """
  end
end

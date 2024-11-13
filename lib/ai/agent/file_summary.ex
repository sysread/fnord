defmodule AI.Agent.FileSummary do
  @moduledoc """
  This module provides an agent that summarizes files' contents in order to
  generate embeddings for the database and summaries for the user.
  """

  defstruct [
    :ai,
    :file,
    :splitter,
    :summary
  ]

  @model "gpt-4o-mini"

  # It's actually 128k for this model, but this gives us a little bit of
  # wiggle room in case the tokenizer we are using falls behind.
  @max_tokens 100_000

  @chunk_prompt """
  You are an AI agent that summarizes the content of a file, whether
  it is code or documentation, like an intelligent `ctags`.

  You will process the file in chunks, each paired with an "accumulator" string
  to update. Each input will contain:

  ```
  # Accumulated Summary
  $accumulated_summary
  -----
  $current_file_chunk
  ```

  Your task is to build on the existing summary with each chunk, adhering to
  these guidelines:

  ### General Guidelines:
  - Add Relevant Content: Update the accumulated summary by adding notes relevant to the current chunk.
  - Structure and Continuity: Preserve the structure of the summary, maintaining a coherent flow for cross-referencing across chunks.
  - Mark Incomplete Sections: If a section seems incomplete, label it `<partial>` to complete later.
  - Avoid Redundancy: Avoid duplicating details already present unless it clarifies key linkages or structure.

  Based on the file type, update the accumulated summary as follows:

  ### For Code Files:
  - Synopsis: Briefly summarize the purpose of the code file.
  - Languages Present: List programming languages used.
  - Business Logic and Behaviors: Summarize main functions, classes, and business logic. Highlight any patterns or distinctive behaviors.
  - List of Symbols: List important classes, functions, variables, and constants, with brief descriptions.
  - Map of Calls to Other Modules: Track calls to other modules or dependencies. Include a *map format* such as `FunctionA -> ModuleX:MethodY`, focusing on interactions relevant to functionality and semantics.

  ### For Documentation Files (e.g., README, Wiki Pages, General Documentation):
  - Synopsis: Summarize the document's primary purpose.
  - Topics and Sections: List main topics or sections in the document.
  - Definitions and Key Terms: Note specialized terms and definitions.
  - Links and References: Include any links or references, especially to related files, modules, or external resources.
  - Key Points and Highlights: Summarize main points, noting insights that would aid semantic search.

  Only use information from the file itself to ensure accurate summaries
  without false positives from external sources.

  Respond ONLY with the updated `Accumulated Summary` section in markdown
  format, adding content from the current chunk as needed.
  """

  @final_prompt """
  You have processed a file in chunks, using an accumulated summary to track
  relevant details. Now, review and consolidate this accumulated summary into a
  cohesive, final summary of the file's contents.

  Your input will contain:
  ```
  # Accumulated Summary
  $accumulated_summary
  ```

  Please follow these steps as you create the final summary:

  ### General Guidelines:
  - Reorganize for Clarity: Organize content logically, ensuring all details flow smoothly and follow the structure below.
  - Eliminate Redundancy: Avoid duplicate information or unnecessary repetition from the accumulated notes.
  - Ensure Completeness: Ensure all sections and details are covered, completing any previously marked `<partial>` sections.
  - Optimize for Semantic Matching: Select details that best support semantic search, especially key linkages between code or document topics.

  ### Final Summary Structure
  Based on the file type (Code or Documentation), structure your final summary as follows:

  #### For Code Files:
  - Synopsis: Briefly summarize the overall purpose of the code file.
  - Languages Present: List any programming languages used.
  - Business Logic and Behaviors: Summarize main functions, classes, business logic, and any distinctive patterns or behaviors.
  - Note any oddball configuration or unexpected aspects of the code or how it is organized.
  - List of Symbols: Provide a concise list of important classes, functions, variables, and constants, with brief descriptions if available.
  - Map of Calls to Other Modules: Use the format `FunctionA -> ModuleX:MethodY` to document inter-module calls, highlighting links relevant for understanding dependencies and functionality.

  #### For Documentation Files (e.g., README, Wiki Pages, General Documentation):
  - Synopsis: Briefly describe the main purpose or scope of the document.
  - Topics and Sections: List the main topics or sections in the document.
  - Definitions and Key Terms: Note any specialized terms or jargon defined in the document.
  - Links and References: Include any important links or references, particularly those linking to code files or other documents.
  - Key Points and Highlights: Summarize the main points or insights relevant for understanding core topics.

  Respond ONLY with the final, organized summary in markdown format, excluding
  the "Accumulated Summary" header, following the structure for either code or
  documentation files. Ensure the summary is clear, concise, and includes only
  the relevant details from the file itself.
  """

  def get_summary(ai, file, file_content) do
    %__MODULE__{
      ai: ai,
      file: file,
      splitter: AI.TokenSplitter.new(file_content, @max_tokens),
      summary: ""
    }
    |> reduce()
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
    # Accumulated Summary
    #{agent.summary}
    -----

    """
  end
end

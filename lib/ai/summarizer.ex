defmodule AI.Summarizer do
  @moduledoc """
  This module provides an agent that summarizes files' contents in order to
  generate embeddings for the database and summaries for the user.
  """

  @model "gpt-4o-mini"

  @prompt """
  You are a command line program that summarizes the content of a file, whether
  it is code or documentation, like an intelligent `ctags`.

  Based on the type of file you receive, produce the following data:

  ### For Code Files:
    - **Synopsis**
    - **Languages present in the file**
    - **Business logic and behaviors**
    - **List of symbols**
    - **Map of calls to other modules**

  ### For Documentation Files (e.g., README, Wiki Pages, General Documentation):
    - **Synopsis**: A brief overview of what the document covers.
    - **Topics and Sections**: A list of main topics or sections in the document.
    - **Definitions and Key Terms**: Any specialized terms or jargon defined in the document.
    - **Links and References**: Important links or references included in the document.
    - **Key Points and Highlights**: Main points or takeaways from the document.

  Restrict your analysis to only what appears in the file. This is used to
  generate a search index, so we want to avoid false positives from external
  sources.

  Respond ONLY with your markdown-formatted summary.
  """

  @doc """
  Get a summary of the given text. The text is truncated to 128k tokens to
  avoid exceeding the model's input limit. Returns a summary of the text.
  """
  def get_summary(ai, file, text) do
    input = "# File name: #{file}\n```\n#{text}\n```"

    # The model is limited to 128k tokens input, so, for now, we'll just
    # truncate the input if it's too long.
    input = AI.Util.truncate_text(input, 128_000)

    OpenaiEx.Chat.Completions.create(
      ai.client,
      OpenaiEx.Chat.Completions.new(
        model: @model,
        messages: [
          OpenaiEx.ChatMessage.system(@prompt),
          OpenaiEx.ChatMessage.user(input)
        ]
      )
    )
    |> case do
      {:ok, %{"choices" => [%{"message" => %{"content" => summary}}]}} -> {:ok, summary}
      {:error, reason} -> {:error, reason}
      response -> {:error, "unexpected response: #{inspect(response)}"}
    end
  end
end

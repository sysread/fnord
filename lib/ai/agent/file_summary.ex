defmodule AI.Agent.FileSummary do
  @moduledoc """
  This module provides an agent that summarizes files' contents in order to
  generate embeddings for the database and summaries for the user.
  """
  @model "gpt-4o-mini"

  # It's actually 128k for this model, but this gives us a little bit of
  # wiggle room in case the tokenizer we are using falls behind.
  @max_tokens 100_000

  @prompt """
  You are an AI agent that summarizes the content of a file, whether it is code or documentation, thoroughly documenting its internal implementation and public interface.

  Based on the file type, update the accumulated summary as follows:

  ## For Code Files:
  - Synopsis: Briefly summarize the purpose of the code file.
  - Languages Present: List programming languages used.
  - Public Interface: List main classes, functions, and variables that are part of the public interface. For languages that do not distinguish public and private:
    - assume entities prefixed with an underscore are private
    - assume entities that are not used within the file are public
    - beyond those, use your best judgment based on the language's conventions
  - Implementation Details: THOROUGHLY document the internal implementation, highlighting connections between components within the file
  - Business Logic and Behaviors: Summarize the the behavior of the code from a product/feature perspective
  - Note any oddball configuration or unexpected aspects of the code or how it is organized.
  - List questions that can be answered by the content of the file.

  ## For Documentation Files (e.g., README, Wiki Pages, General Documentation):
  - Synopsis: Summarize the document's primary purpose.
  - Topics and Sections: List main topics or sections in the document.
  - Definitions and Key Terms: Note specialized terms and definitions.
  - Links and References: Include any links or references, especially to related files, modules, or external resources.
  - Key Points and Highlights: Summarize main points, noting insights that would aid semantic search.
  - List questions that can be answered by the content of the file.

  Only use information from the file itself to ensure accurate summaries without false positives from external sources.
  """

  def get_response(ai, file, content) do
    AI.Accumulator.get_response(ai,
      max_tokens: @max_tokens,
      model: @model,
      prompt: @prompt,
      input: content,
      question: "Summarize the content of the file: #{file}"
    )
  end
end

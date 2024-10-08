defmodule AI do
  @moduledoc """
  AI is a behavior module that defines the interface for interacting with
  OpenAI's API. It provides a common interface for the various OpenAI-powered
  operations used by the application.
  """

  defstruct [:client]

  @api_key System.get_env("OPENAI_API_KEY")
  @api_timeout 45_000

  @embedding_model "text-embedding-3-large"
  @summary_model "gpt-4o-mini"
  @summary_prompt """
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

  @callback new() :: struct()
  @callback get_embeddings(struct(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  @callback get_summary(struct(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}

  @behaviour AI

  @impl AI
  @doc """
  Create a new AI instance. Instances share the same client connection.
  """
  def new() do
    openai = OpenaiEx.new(@api_key) |> OpenaiEx.with_receive_timeout(@api_timeout)
    %AI{client: openai}
  end

  @impl AI
  @doc """
  Get embeddings for the given text. The text is split into chunks of 8192
  tokens to avoid exceeding the model's input limit. Returns a list of
  embeddings for each chunk.
  """
  def get_embeddings(ai, text) do
    embeddings =
      split_text(text, 8192)
      |> Enum.map(fn chunk ->
        OpenaiEx.Embeddings.create(
          ai.client,
          OpenaiEx.Embeddings.new(
            model: @embedding_model,
            input: chunk
          )
        )
        |> case do
          {:ok, %{"data" => [%{"embedding" => embedding}]}} -> embedding
          _ -> nil
        end
      end)
      |> Enum.filter(fn x -> not is_nil(x) end)

    {:ok, embeddings}
  end

  @impl AI
  @doc """
  Get a summary of the given text. The text is truncated to 128k tokens to
  avoid exceeding the model's input limit. Returns a summary of the text.
  """
  def get_summary(ai, file, text) do
    input = "# File name: #{file}\n```\n#{text}\n```"

    # The model is limited to 128k tokens input, so, for now, we'll just
    # truncate the input if it's too long.
    input = truncate_text(input, 128_000)

    OpenaiEx.Chat.Completions.create(
      ai.client,
      OpenaiEx.Chat.Completions.new(
        model: @summary_model,
        messages: [
          OpenaiEx.ChatMessage.system(@summary_prompt),
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

  defp truncate_text(text, max_tokens) do
    if String.length(text) > max_tokens do
      String.slice(text, 0, max_tokens)
    else
      text
    end
  end

  defp split_text(input, max_tokens) do
    Gpt3Tokenizer.encode(input)
    |> Enum.chunk_every(max_tokens)
    |> Enum.map(&Gpt3Tokenizer.decode(&1))
  end
end

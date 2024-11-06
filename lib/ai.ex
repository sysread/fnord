defmodule AI do
  @moduledoc """
  AI is a behavior module that defines the interface for interacting with
  OpenAI's API. It provides a common interface for the various OpenAI-powered
  operations used by the application.
  """

  defstruct [:client]

  @api_key System.get_env("OPENAI_API_KEY")

  @openai_config %OpenAI.Config{
    api_key: @api_key,
    beta: "assistants=v2"
  }

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

  @callback get_embeddings(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  @callback get_summary(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}

  @behaviour AI

  # -----------------------------------------------------------------------------
  # Embeddings
  # -----------------------------------------------------------------------------

  @impl AI
  @doc """
  Get embeddings for the given text. The text is split into chunks of 8192
  tokens to avoid exceeding the model's input limit. Returns a list of
  embeddings for each chunk.
  """
  def get_embeddings(text) do
    embeddings =
      split_text(text, 8192)
      |> Enum.map(fn chunk ->
        OpenAI.embeddings(
          [
            model: @embedding_model,
            input: chunk
          ],
          @openai_config
        )
        |> case do
          {:ok, %{data: [%{"embedding" => embedding}]}} -> embedding
          _ -> nil
        end
      end)
      |> Enum.filter(fn x -> not is_nil(x) end)

    {:ok, embeddings}
  end

  # -----------------------------------------------------------------------------
  # Summaries
  # -----------------------------------------------------------------------------

  @impl AI
  @doc """
  Get a summary of the given text. The text is truncated to 128k tokens to
  avoid exceeding the model's input limit. Returns a summary of the text.
  """
  def get_summary(file, text) do
    input = "# File name: #{file}\n```\n#{text}\n```"

    # The model is limited to 128k tokens input, so, for now, we'll just
    # truncate the input if it's too long.
    input = truncate_text(input, 128_000)

    OpenAI.chat_completion(
      [
        model: @summary_model,
        messages: [
          %{role: "system", content: @summary_prompt},
          %{role: "user", content: input}
        ]
      ],
      @openai_config
    )
    |> case do
      {:ok, %{choices: [%{"message" => %{"content" => summary}}]}} -> {:ok, summary}
      {:error, reason} -> {:error, reason}
      response -> {:error, "unexpected response: #{inspect(response)}"}
    end
  end

  # -----------------------------------------------------------------------------
  # Assistants
  # -----------------------------------------------------------------------------
  def create_assistant(params) do
    OpenAI.assistants_create(params, @openai_config)
  end

  def get_assistant(assistant_id) do
    OpenAI.assistants(assistant_id, @openai_config)
  end

  def update_assistant(assistant_id, params) do
    OpenAI.assistants_modify(assistant_id, params, @openai_config)
  end

  # -----------------------------------------------------------------------------
  # Threads
  # -----------------------------------------------------------------------------
  def start_thread() do
    OpenAI.threads_create([], @openai_config)
    |> case do
      {:ok, %{id: thread_id}} -> {:ok, thread_id}
      {:error, reason} -> {:error, reason}
    end
  end

  def add_user_message(thread_id, message) do
    OpenAI.thread_message_create(
      thread_id,
      [role: "user", content: message],
      @openai_config
    )
    |> case do
      {:ok, %{id: message_id}} -> {:ok, message_id}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_messages(thread_id, params \\ []) do
    OpenAI.thread_messages(thread_id, params, @openai_config)
  end

  def run_thread(assistant_id, thread_id) do
    OpenAI.thread_run_create(thread_id, [assistant_id: assistant_id], @openai_config)
    |> case do
      {:ok, %{id: run_id}} -> {:ok, run_id}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_thread_run(thread_id, run_id) do
    OpenAI.thread_run(thread_id, run_id, @openai_config)
    |> case do
      {:ok, thread_run} -> {:ok, thread_run}
      {:error, reason} -> {:error, reason}
    end
  end

  def submit_tool_outputs(thread_id, run_id, outputs) do
    OpenAI.thread_run_submit_tool_outputs(
      thread_id,
      run_id,
      [tool_outputs: outputs],
      @openai_config
    )
  end

  # -----------------------------------------------------------------------------
  # Utilities
  # -----------------------------------------------------------------------------
  defp truncate_text(text, max_tokens) do
    if String.length(text) > max_tokens do
      String.slice(text, 0, max_tokens)
    else
      text
    end
  end

  def split_text(input, max_tokens) do
    Gpt3Tokenizer.encode(input)
    |> Enum.chunk_every(max_tokens)
    |> Enum.map(&Gpt3Tokenizer.decode(&1))
  end
end

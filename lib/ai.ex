defmodule AI do
  defstruct [:client]

  @api_key System.get_env("OPENAI_API_KEY")
  @api_timeout 45_000

  @embedding_model "text-embedding-3-large"
  @summary_model "gpt-4o-mini"
  @summary_prompt """
  You are a command line program that summarizes the content of a code file.
  Respond ONLY with a markdown-formatted summary of the content.
  """

  def new() do
    openai = OpenaiEx.new(@api_key) |> OpenaiEx.with_receive_timeout(@api_timeout)
    %AI{client: openai}
  end

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

  def get_summary(ai, file, text) do
    input = """
      # File name: #{file}
      ```
      #{text}
      ```
    """

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

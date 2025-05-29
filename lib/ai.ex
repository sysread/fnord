defmodule AI do
  @moduledoc """
  AI is a behavior module that defines the interface for interacting with
  OpenAI's API. It provides a common interface for the various OpenAI-powered
  operations used by the application.
  """

  defstruct [
    :client,
    :api_key
  ]

  @type t :: %__MODULE__{
          client: %AI.OpenAI{}
        }

  @api_timeout 5 * 60 * 1000
  @default_max_attempts 3
  @retry_interval 250

  @doc """
  Create a new AI instance. Instances share the same client connection.
  """
  def new() do
    client = AI.OpenAI.new(recv_timeout: @api_timeout)
    %AI{client: client}
  end

  # -----------------------------------------------------------------------------
  # Completions
  # -----------------------------------------------------------------------------
  def get_completion(ai, model, msgs, tools) do
    request = [ai.client, model, msgs, tools]
    do_get_completion(ai, request, @default_max_attempts, 1)
  end

  defp do_get_completion(_ai, _request, max, attempt) when attempt > max do
    {:error, "Request timed out after #{attempt} attempts."}
  end

  defp do_get_completion(ai, request, max, attempt) do
    if attempt > 1, do: Process.sleep(@retry_interval)

    AI.OpenAI
    |> apply(:get_completion, request)
    |> case do
      {:error, :timeout} -> do_get_completion(ai, request, max, attempt + 1)
      etc -> etc
    end
  end

  # -----------------------------------------------------------------------------
  # Embeddings
  # -----------------------------------------------------------------------------
  @embeddings_model AI.Model.embeddings()

  @doc """
  Identical to `get_embeddings/2`, but raises an error if the request fails.
  """
  def get_embeddings!(ai, text) do
    with {:ok, embeddings} <- get_embeddings(ai, text) do
      embeddings
    else
      {:error, reason} -> raise reason
    end
  end

  @doc """
  Get embeddings for the given text. The text is split into chunks of 8192
  tokens to avoid exceeding the model's input limit. Returns a list of
  embeddings for each chunk.

  This function will retry the request up to `@default_max_attempts` times.
  Each time it makes a new attempt, it dials back the number of tokens
  processed by 10% to avoid hitting the model's input limit.
  """
  def get_embeddings(ai, text, attempt \\ 1)

  def get_embeddings(_ai, _text, attempt) when attempt > @default_max_attempts do
    {:error, :max_attempts_reached}
  end

  def get_embeddings(ai, text, attempt) do
    if AI.PretendTokenizer.over_max_for_openai_embeddings?(text) do
      {:error, :input_too_large}
    else
      # Since we only guesstimate token counts, we dial back the context window
      # by an increasingly larger factor with each attempt.
      reduction_factor =
        case attempt do
          1 -> 0.75
          2 -> 0.50
          _ -> 0.25
        end

      chunks = AI.PretendTokenizer.chunk(text, @embeddings_model, reduction_factor)

      AI.OpenAI.get_embedding(ai.client, @embeddings_model, chunks)
      |> case do
        {:ok, embeddings} ->
          # For each dimension, find the maximum value across all embeddings.
          # This isn't necessarily the _most_ accurate, but it selects the
          # highest rating for each dimension found in the file, which should be
          # reasonable for semantic searching.
          embeddings
          |> Enum.reduce_while([], fn
            embedding, [] -> {:cont, embedding}
            embedding, acc -> {:cont, Enum.zip_with(acc, embedding, fn a, b -> max(a, b) end)}
          end)
          |> then(&{:ok, &1})

        {:error, reason} ->
          if attempt < @default_max_attempts do
            Process.sleep(@retry_interval)
            get_embeddings(ai, text, attempt + 1)
          else
            {:error, reason}
          end
      end
    end
  end
end

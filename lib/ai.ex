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
  """
  def get_embeddings(ai, text) do
    text
    |> AI.Tokenizer.chunk(@embeddings_model)
    |> Enum.map(&[ai.client, @embeddings_model, &1])
    |> Enum.reduce_while([], fn request, acc ->
      ai
      |> get_embedding(request, @default_max_attempts, 1)
      |> case do
        {:ok, embedding} ->
          if acc == [] do
            {:cont, embedding}
          else
            # For each dimension, find the maximum value across all embeddings.
            # This isn't necessarily the _most_ accurate, but it selects the
            # highest rating for each dimension found in the file, which should
            # be reasonable for semantic searching.
            {:cont, Enum.zip_with(acc, embedding, fn a, b -> max(a, b) end)}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, reason} -> {:error, inspect(reason)}
      embeddings -> {:ok, embeddings}
    end
  end

  defp get_embedding(_ai, _request, max, attempt) when attempt > max do
    {:error, "Request timed out after #{attempt} attempts."}
  end

  defp get_embedding(ai, request, max, attempt) do
    if attempt > 1 do
      Process.sleep(@retry_interval)
    end

    AI.OpenAI
    |> apply(:get_embedding, request)
    |> case do
      {:error, :timeout} -> get_embedding(ai, request, max, attempt + 1)
      etc -> etc
    end
  end
end

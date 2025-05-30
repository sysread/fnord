defmodule AI.Embeddings do
  @endpoint "https://api.openai.com/v1/embeddings"
  @retry_interval 250
  @max_attempts 3

  @model "text-embedding-3-large"
  @batch_size 300_000
  @batch_reduction_factor 0.75
  @chunk_size 8192

  @type embedding :: list(float())
  @type embeddings :: list(embedding())

  @type error ::
          {:error, :max_attempts_reached}
          | {:error, :http_error}
          | {:error, :transport_error}
          | {:error, String.t()}

  @typep attempt :: non_neg_integer()
  @typep inputs :: list(String.t())

  @spec get(String.t()) :: {:ok, embeddings} | error
  def get(input) do
    input
    |> split_into_batches()
    |> get(1, [])
  end

  @spec get(inputs, attempt, embeddings) :: {:ok, embeddings} | error
  defp get(batches, attempt, acc)
  defp get([], _attempt, acc), do: {:ok, acc}

  defp get(_batches, attempt, _acc) when attempt > @max_attempts do
    {:error, :max_attempts_reached}
  end

  defp get([batch | rest], attempt, acc) do
    if attempt > 1, do: Process.sleep(@retry_interval)

    batch
    |> split_into_chunks(attempt)
    |> endpoint()
    |> case do
      {:ok, embeddings} ->
        get(rest, 1, merge_embeddings(embeddings, acc))

      {:error, :token_limit_exceeded} ->
        get([batch | rest], attempt + 1, acc)

      other ->
        {:error, other}
    end
  end

  @spec split_into_batches(String.t()) :: inputs
  defp split_into_batches(input) do
    tokens = AI.PretendTokenizer.guesstimate_tokens(input)

    if tokens >= @batch_size do
      AI.PretendTokenizer.chunk(input, @batch_size, @batch_reduction_factor)
    else
      [input]
    end
  end

  @spec split_into_chunks(String.t(), attempt) :: inputs
  defp split_into_chunks(batch, attempt) do
    reduction_factor = token_reduction_factor(attempt)
    AI.PretendTokenizer.chunk(batch, @chunk_size, reduction_factor)
  end

  # -----------------------------------------------------------------------------
  # For each dimension, find the maximum value across all embeddings. This
  # isn't necessarily the _most_ accurate, but it selects the highest rating
  # for each dimension found in the file, which should be reasonable for
  # semantic searching.
  # -----------------------------------------------------------------------------
  @spec merge_embeddings(embeddings, embedding) :: embeddings | error
  defp merge_embeddings([], acc), do: acc
  defp merge_embeddings([first | rest], []), do: merge_embeddings(rest, first)

  defp merge_embeddings([first | rest], acc) do
    merged = Enum.zip_with(acc, first, &max/2)
    merge_embeddings(rest, merged)
  end

  @spec get_api_key!() :: String.t()
  defp get_api_key!() do
    ["FNORD_OPENAI_API_KEY", "OPENAI_API_KEY"]
    |> Enum.find_value(&System.get_env(&1, nil))
    |> case do
      nil ->
        raise "Either FNORD_OPENAI_API_KEY or OPENAI_API_KEY environment variable must be set"

      api_key ->
        api_key
    end
  end

  # -----------------------------------------------------------------------------
  # Calculate the token reduction factor based on the number of attempts. This
  # is used to dial back the number of (estimated) tokens sent to the endpoint
  # when retrying requests.
  # -----------------------------------------------------------------------------
  @spec token_reduction_factor(attempt) :: float()
  defp token_reduction_factor(attempt) do
    case attempt do
      1 -> 0.75
      2 -> 0.50
      _ -> 0.25
    end
  end

  @spec token_limit_error?(String.t()) :: boolean
  defp token_limit_error?(body) do
    String.contains?(body, "maximum context length")
  end

  @spec endpoint(inputs) ::
          {:ok, embeddings}
          | {:error, :token_limit_exceeded}
          | {:error, :http_error}
          | {:error, :transport_error}

  defp endpoint(input) do
    api_key = get_api_key!()

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    payload =
      %{
        encoding_format: "float",
        model: @model,
        input: input
      }

    Http.post_json(@endpoint, headers, payload)
    |> case do
      {:ok, %{"data" => embeddings}} ->
        {:ok, Enum.map(embeddings, &Map.get(&1, "embedding"))}

      {:http_error, {status_code, message}} ->
        if token_limit_error?(message) do
          {:error, :token_limit_exceeded}
        else
          UI.warn("[AI.Embeddings] Error getting embeddings: #{status_code} - #{message}")
          {:error, :http_error}
        end

      {:transport_error, error} ->
        UI.warn("[AI.Embeddings] Error getting embeddings: #{inspect(error)}")
        {:error, :transport_error}
    end
  end
end

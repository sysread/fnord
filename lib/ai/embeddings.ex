defmodule AI.Embeddings do
  @behaviour AI.Endpoint
  @base_url "https://api.openai.com"

  # Upper bound on attempts to work around token limit exceeded errors.
  @max_attempts 3

  # Short wait between retries to avoid server-side rate limiting.
  @retry_interval 250

  @model "text-embedding-3-large"
  @batch_size 300_000
  @batch_reduction_factor 0.75
  @chunk_size 8192

  @impl AI.Endpoint
  def endpoint_path(), do: "#{@base_url}/v1/embeddings"

  @doc "Returns the embeddings model name."
  @spec model_name() :: String.t()
  def model_name(), do: @model

  @type embedding :: list(float())
  @type embeddings :: list(embedding())

  @type error ::
          {:error, :max_attempts_reached}
          | {:error, :http_error}
          | {:error, :transport_error}
          | {:error, String.t()}

  @type attempt :: non_neg_integer()
  @type inputs :: list(String.t())

  @doc """
  Centralizes embeddings generation for all upstream producers and recovers from
  oversize inputs by progressively retrying smaller chunks.
  """
  @spec get(String.t()) :: {:ok, embeddings} | error
  def get(input) do
    input
    |> split_into_batches()
    |> get_batches(1, [])
  end

  @spec get_batches(inputs, attempt, embeddings) :: {:ok, embeddings} | error
  defp get_batches([], _attempt, acc), do: {:ok, acc}

  defp get_batches([batch | rest], attempt, acc) do
    case process_batch(batch, attempt) do
      {:ok, embeddings} ->
        get_batches(rest, 1, merge_embeddings(embeddings, acc))

      {:retry, smaller_batches} ->
        sleep_before_retry(attempt)
        get_batches(smaller_batches ++ rest, attempt + 1, acc)

      {:error, reason} when is_atom(reason) or is_binary(reason) ->
        {:error, reason}
    end
  end

  @spec process_batch(String.t(), attempt) :: {:ok, embeddings} | {:retry, inputs} | error
  defp process_batch(batch, attempt) do
    batch
    |> split_into_chunks(attempt)
    |> endpoint()
    |> case do
      {:ok, embeddings} ->
        {:ok, embeddings}

      {:error, :token_limit_exceeded} ->
        retry_with_smaller_batch(batch, attempt)

      {:error, reason} when is_atom(reason) or is_binary(reason) ->
        {:error, reason}
    end
  end

  @spec retry_with_smaller_batch(String.t(), attempt) :: {:retry, inputs} | error
  defp retry_with_smaller_batch(_batch, attempt) when attempt >= @max_attempts do
    {:error, :max_attempts_reached}
  end

  defp retry_with_smaller_batch(batch, attempt) do
    split_batch_for_retry(batch, attempt + 1)
  end

  @spec split_batch_for_retry(String.t(), attempt) :: {:retry, inputs} | error
  defp split_batch_for_retry(batch, attempt) do
    reduction_factor = token_reduction_factor(attempt)
    smaller_batches = AI.PretendTokenizer.chunk(batch, @chunk_size, reduction_factor)

    case smaller_batches do
      [] ->
        {:error, :max_attempts_reached}

      [^batch] ->
        {:error, :max_attempts_reached}

      batches ->
        {:retry, batches}
    end
  end

  @spec sleep_before_retry(attempt) :: :ok
  defp sleep_before_retry(attempt) when attempt > 1 do
    Process.sleep(@retry_interval)
    :ok
  end

  defp sleep_before_retry(_attempt), do: :ok

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
    |> Enum.find_value(fn k -> Util.Env.get_env(k, nil) end)
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
    case decode_body(body) do
      {:ok, decoded_body} ->
        token_limit_error_in_decoded_body?(decoded_body) or token_limit_phrase?(body)

      :error ->
        token_limit_phrase?(body)
    end
  end

  @spec decode_body(String.t()) :: {:ok, term()} | :error
  defp decode_body(body) do
    case SafeJson.decode(body) do
      {:ok, decoded_body} -> {:ok, decoded_body}
      {:error, _reason} -> :error
    end
  end

  @spec token_limit_error_in_decoded_body?(term()) :: boolean
  defp token_limit_error_in_decoded_body?(decoded_body)

  defp token_limit_error_in_decoded_body?(%{"error" => error}) do
    token_limit_error_map?(error) or token_limit_error_string?(error)
  end

  defp token_limit_error_in_decoded_body?(%{"message" => message}) do
    token_limit_error_string?(message)
  end

  defp token_limit_error_in_decoded_body?(%{"errors" => errors}) when is_list(errors) do
    Enum.any?(errors, &token_limit_error_in_decoded_body?/1)
  end

  defp token_limit_error_in_decoded_body?(%{} = decoded_body) do
    Enum.any?(decoded_body, fn {_key, value} -> token_limit_error_in_decoded_body?(value) end)
  end

  defp token_limit_error_in_decoded_body?(decoded_body) when is_list(decoded_body) do
    Enum.any?(decoded_body, &token_limit_error_in_decoded_body?/1)
  end

  defp token_limit_error_in_decoded_body?(_), do: false

  @spec token_limit_error_map?(map()) :: boolean
  defp token_limit_error_map?(error) when is_map(error) do
    token_limit_error_code?(Map.get(error, "code")) or
      token_limit_error_code?(Map.get(error, :code)) or
      token_limit_error_string?(Map.get(error, "message")) or
      token_limit_error_string?(Map.get(error, :message)) or
      token_limit_error_in_decoded_body?(Map.get(error, "error")) or
      token_limit_error_in_decoded_body?(Map.get(error, :error))
  end

  defp token_limit_error_map?(_), do: false

  @spec token_limit_error_string?(term()) :: boolean
  defp token_limit_error_string?(value) when is_binary(value) do
    token_limit_phrase?(value)
  end

  defp token_limit_error_string?(_), do: false

  @spec token_limit_phrase?(String.t()) :: boolean
  defp token_limit_phrase?(body) do
    String.contains?(body, [
      "maximum input length",
      "maximum context length",
      "token limit",
      "context length"
    ])
  end

  @spec token_limit_error_code?(term()) :: boolean
  defp token_limit_error_code?(code) when is_binary(code) do
    code in ["context_length_exceeded", "token_limit_exceeded", "max_tokens_exceeded"]
  end

  defp token_limit_error_code?(_), do: false

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

    payload = %{
      encoding_format: "float",
      model: @model,
      input: input
    }

    AI.Endpoint.post_json(__MODULE__, headers, payload)
    |> case do
      {:ok, %{body: %{"data" => embeddings}}} ->
        {:ok, Enum.map(embeddings, &Map.get(&1, "embedding"))}

      {:http_error, {status_code, body}} ->
        handle_http_error(status_code, body)

      {:transport_error, error} ->
        UI.warn("[AI.Embeddings] Error getting embeddings: #{inspect(error)}")
        {:error, :transport_error}
    end
  end

  @spec handle_http_error(integer(), String.t()) ::
          {:error, :token_limit_exceeded} | {:error, :http_error}
  defp handle_http_error(_status_code, body) do
    case token_limit_error?(body) do
      true -> {:error, :token_limit_exceeded}
      false -> warn_http_error(body)
    end
  end

  @spec warn_http_error(String.t()) :: {:error, :http_error}
  defp warn_http_error(body) do
    UI.warn("[AI.Embeddings] Error getting embeddings: #{body}")
    {:error, :http_error}
  end
end

defmodule Store.APIUsage do
  @moduledoc """
  Module for recording and checking API usage data. Cross OS process
  coordination is handled with regard to file reads/writes. It is up to the
  caller to ensure that requests are internally ordered for consistency.
  """

  @path "usage.json"
  @tag "[usage]"
  @re_reset ~r/^(\d+)(ms|s)$/
  @debug_env_var "FNORD_DEBUG_API_USAGE"

  @type model_usage :: %{
          updated_at: non_neg_integer,
          requests_max: non_neg_integer,
          requests_left: non_neg_integer,
          requests_reset: non_neg_integer,
          tokens_max: non_neg_integer,
          tokens_left: non_neg_integer,
          tokens_reset: non_neg_integer
        }

  @type usage :: %{
          optional(binary) => model_usage
        }

  @typep http_response ::
           {:ok, HTTPoison.Response.t()}
           | {:error, HTTPoison.Error.t()}

  @doc """
  Returns the path to the usage store file.
  """
  @spec store_path() :: binary
  def store_path do
    Path.join(Store.store_home(), @path)
  end

  @doc """
  Records API usage data from an HTTPoison response. If the response does not
  contain usage data, it is returned unmodified.
  """
  @spec record(http_response) :: http_response
  def record({:ok, %HTTPoison.Response{headers: headers, body: body} = response}) do
    ensure_store_file()
    headers = Enum.into(headers, %{})

    with {:ok, model} <- identify_model(headers, body),
         {:ok, usage} <- collect_usage_data(headers),
         :ok <- update_file(model, usage) do
      case System.get_env(@debug_env_var, nil) do
        "" -> false
        "0" -> false
        0 -> false
        nil -> false
        _ -> UI.debug(@tag, "#{model}: #{inspect(usage, pretty: true)}")
      end
    else
      reason ->
        UI.warn(@tag, """
        Failed to record API usage data

        Reason:
        #{inspect(reason, pretty: true)}

        Response:
        #{inspect(response, pretty: true)}
        """)
    end

    {:ok, response}
  end

  def record(other), do: other

  @doc """
  Checks if a request can be made for the given model based on the last
  recorded usage data for the model. If a request can be made, returns `:ok`.
  Otherwise, returns `{:wait, milliseconds}` indicating how long to wait before
  attempting another request.
  """
  @spec check(binary) ::
          :ok
          | {:wait, non_neg_integer}
          | {:error, term}
  def check(model) do
    ensure_store_file()

    with :ok <- can_request?(model) do
      :ok
    end
  end

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------
  @spec can_request?(binary) ::
          :ok
          | {:wait, non_neg_integer}
          | {:error, term}
  defp can_request?(model) do
    FileLock.with_lock(store_path(), fn ->
      with {:ok, data} <- read_file() do
        usage = Map.get(data, model, %{})
        updated_at = Map.get(usage, :updated_at, 0)
        elapsed_time = now() - updated_at
        requests_reset = Map.get(usage, :requests_reset, 0)

        if requests_reset <= elapsed_time do
          :ok
        else
          {:wait, requests_reset - elapsed_time}
        end
      end
    end)
    |> case do
      {:ok, result} -> result
      {:callback_error, exc} -> {:error, exc}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_file(binary, model_usage) :: :ok | {:error, term}
  defp update_file(model, usage) do
    FileLock.with_lock(store_path(), fn ->
      with {:ok, usage_data} <- read_file() do
        usage = Map.put(usage, :updated_at, now())
        payload = Map.put(usage_data, model, usage)
        write_file(payload)
      end
    end)
    |> case do
      {:ok, result} -> result
      {:callback_error, exc} -> {:error, exc}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec read_file() :: {:ok, usage} | {:error, term}
  defp read_file do
    with {:ok, json} <- File.read(store_path()),
         {:ok, data} <- Jason.decode(json) do
      data
      |> Enum.map(fn {model, usage} ->
        {model, Util.string_keys_to_atoms(usage)}
      end)
      |> Enum.into(%{})
      |> then(&{:ok, &1})
    end
  end

  @spec write_file(map) :: :ok | {:error, term}
  defp write_file(data) do
    with {:ok, json} <- Jason.encode(data, pretty: true) do
      File.write(store_path(), json)
    end
  end

  @spec collect_usage_data(map) :: {:ok, model_usage} | {:error, atom, binary}
  defp collect_usage_data(headers) do
    with {:ok, requests_max} <- collect_usage_metric(headers, "x-ratelimit-limit-requests"),
         {:ok, requests_left} <- collect_usage_metric(headers, "x-ratelimit-remaining-requests"),
         {:ok, requests_reset} <- collect_reset_metric(headers, "x-ratelimit-reset-requests"),
         {:ok, tokens_max} <- collect_usage_metric(headers, "x-ratelimit-limit-tokens"),
         {:ok, tokens_left} <- collect_usage_metric(headers, "x-ratelimit-remaining-tokens"),
         {:ok, tokens_reset} <- collect_reset_metric(headers, "x-ratelimit-reset-tokens") do
      {:ok,
       %{
         updated_at: now(),
         requests_max: requests_max,
         requests_left: requests_left,
         requests_reset: requests_reset,
         tokens_max: tokens_max,
         tokens_left: tokens_left,
         tokens_reset: tokens_reset
       }}
    end
  end

  @spec collect_usage_metric(map, binary) :: {:ok, integer} | {:error, atom, binary}
  defp collect_usage_metric(headers, key) do
    headers
    |> Map.fetch(key)
    |> case do
      {:ok, value} ->
        value
        |> Integer.parse()
        |> case do
          {int_value, _} -> {:ok, int_value}
          :error -> {:error, :invalid_integer}
        end

      :error ->
        {:error, :not_found, key}
    end
  end

  @spec collect_reset_metric(map, binary) :: {:ok, integer} | {:error, atom, binary}
  defp collect_reset_metric(headers, key) do
    headers
    |> Map.fetch(key)
    |> case do
      # In "2ms" or "1s" format
      {:ok, value} -> parse_reset_metric(value)
      :error -> {:error, :not_found, key}
    end
  end

  @spec parse_reset_metric(binary) :: {:ok, non_neg_integer} | {:error, atom, binary}
  defp parse_reset_metric(value) do
    with [amount, unit] <- Regex.run(@re_reset, value, capture: :all_but_first),
         {int_value, _} <- Integer.parse(amount, 10) do
      ms_value =
        case unit do
          "ms" -> int_value
          "s" -> int_value * 1000
        end

      {:ok, ms_value}
    else
      _ -> {:error, :invalid_reset_format, value}
    end
  end

  @spec identify_model(map, binary) :: {:ok, binary} | {:error, atom}
  defp identify_model(headers, body) do
    with :error <- identify_model_from_headers(headers),
         :error <- identify_model_from_body(body) do
      {:error, :model_not_found}
    end
  end

  @spec identify_model_from_headers(map) :: {:ok, binary} | :error
  defp identify_model_from_headers(headers) do
    headers
    |> Map.fetch("openai-model")
    |> case do
      {:ok, model} -> {:ok, model}
      :error -> :error
    end
  end

  @spec identify_model_from_body(binary) :: {:ok, binary} | :error
  defp identify_model_from_body(body) do
    body
    |> Jason.decode()
    |> case do
      {:ok, %{"model" => model}} -> {:ok, model}
      _ -> :error
    end
  end

  @spec now() :: non_neg_integer
  defp now do
    DateTime.utc_now()
    |> DateTime.to_unix(:millisecond)
  end

  @spec ensure_store_file() :: :ok | {:error, term}
  defp ensure_store_file() do
    path = store_path()

    unless File.exists?(path) do
      File.write(path, "{}")
    end

    :ok
  end
end

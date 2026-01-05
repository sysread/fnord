defmodule AI.Endpoint do
  @moduledoc """
  API endpoint abstraction.

  This behavior encapsulates the common mechanics for calling API endpoints via
  `Http.post_json/3` and applying API-level retry semantics.

  In particular, OpenAI rate limiting is surfaced as HTTP `429` with a JSON
  body containing an error code (commonly `"rate_limit_exceeded"` or
  `"rate_limit"`).

  Callers implement `endpoint_path/0` and then call `AI.Endpoint.post_json/3`.
  """

  @type headers :: list({String.t(), String.t()})
  @type payload :: map()

  @type http_status :: integer()
  @type http_error :: {:http_error, {http_status, String.t()}}
  @type transport_error :: {:transport_error, any()}

  @type success :: {:ok, map()}
  @type response :: success | http_error | transport_error

  @type endpoint :: module()

  @retry_limit 3
  @backoff_base_ms 200
  @backoff_cap_ms 2_000

  # ----------------------------------------------------------------------------
  # Behaviour Callbacks
  # ----------------------------------------------------------------------------
  @callback endpoint_path() :: String.t()

  # ----------------------------------------------------------------------------
  # API
  # ----------------------------------------------------------------------------

  @doc "The fixed retry limit for API calls."
  @spec retry_limit() :: pos_integer()
  def retry_limit, do: @retry_limit

  @doc """
  Perform a JSON POST request against the endpoint module's `endpoint_path/0`.
  Retries up to `#{@retry_limit}` times when the server indicates throttling.
  """
  @spec post_json(endpoint, headers, payload) :: response
  def post_json(endpoint_module, headers, payload) when is_atom(endpoint_module) do
    url = endpoint_module.endpoint_path()
    do_post_json(url, headers, payload, 1)
  end

  defp do_post_json(url, headers, payload, attempt) when attempt <= @retry_limit do
    Http.post_json(url, headers, payload)
    |> case do
      {:http_error, {429, body}} = err ->
        if throttling_error?(body) and attempt < @retry_limit do
          model = model_from_payload(payload)
          Services.BgIndexingControl.note_throttle(model)
          usage_wait = usage_wait_ms(model)
          body_wait = throttling_delay_ms(body)
          backoff_wait = backoff_delay_ms(attempt)

          delay =
            [usage_wait, body_wait, backoff_wait]
            |> Enum.reject(&is_nil/1)
            |> Enum.max()

          UI.warn(
            "[AI.Endpoint] Throttled (429), model=#{inspect(model)}, attempt #{attempt}/#{@retry_limit}, retrying in #{delay}ms"
          )

          maybe_sleep(delay)
          do_post_json(url, headers, payload, attempt + 1)
        else
          err
        end

      {:ok, _} = ok ->
        model = model_from_payload(payload)
        Services.BgIndexingControl.note_success(model)
        ok

      other ->
        other
    end
  end

  defp do_post_json(url, headers, payload, attempt) when attempt > @retry_limit do
    # Should be unreachable because we stop retrying at max-1, but keep for
    # completeness.
    Http.post_json(url, headers, payload)
  end

  defp throttling_error?(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"code" => code}}} when code in ["rate_limit_exceeded", "rate_limit"] ->
        true

      _ ->
        false
    end
  end

  defp model_from_payload(payload) when is_map(payload) do
    cond do
      is_binary(Map.get(payload, :model)) -> Map.get(payload, :model)
      is_binary(Map.get(payload, "model")) -> Map.get(payload, "model")
      true -> nil
    end
  end

  defp usage_wait_ms(nil), do: nil

  defp usage_wait_ms(model) when is_binary(model) do
    case Store.APIUsage.check(model) do
      :ok -> 0
      {:wait, ms} when is_integer(ms) and ms >= 0 -> ms
      {:error, _} -> nil
    end
  end

  defp throttling_delay_ms(body) when is_binary(body) do
    # OpenAI commonly returns a message like:
    # "Please try again in 959ms."
    case Regex.run(~r/try again in (\d+)ms/i, body) do
      [_, ms] ->
        ms
        |> String.to_integer()
        |> max(1)

      _ ->
        nil
    end
  end

  # Exponential backoff with jitter (+/- 20%), capped at 2 seconds.
  defp backoff_delay_ms(attempt) when attempt >= 1 do
    jitter = 0.8 + :rand.uniform() * 0.4

    @backoff_cap_ms
    |> min(@backoff_base_ms * :math.pow(2, attempt - 1))
    |> trunc()
    |> then(&(&1 * jitter))
    |> min(@backoff_cap_ms)
    |> max(1)
    |> round()
  end

  defp maybe_sleep(ms) do
    if Services.Globals.get_env(:fnord, :http_retry_skip_sleep, false) do
      :ok
    else
      Process.sleep(ms)
    end
  end
end

defmodule AI.Endpoint do
  @moduledoc """
  API endpoint abstraction.

  This behavior encapsulates the common mechanics for calling API endpoints via
  `Http.post_json/3` and applying API-level retry semantics.

  In particular, OpenAI rate limiting is surfaced as HTTP `429` with a JSON
  body containing an error code (`"rate_limit_exceeded"`).

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
          delay = throttling_delay_ms(body) || backoff_delay_ms(attempt)

          UI.warn(
            "[AI.Endpoint] Throttled (429), attempt #{attempt}/#{@retry_limit}, retrying in #{delay}ms"
          )

          maybe_sleep(delay)
          do_post_json(url, headers, payload, attempt + 1)
        else
          err
        end

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
      {:ok, %{"error" => %{"code" => "rate_limit_exceeded"}}} -> true
      _ -> false
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
  end

  defp maybe_sleep(ms) do
    if Services.Globals.get_env(:fnord, :http_retry_skip_sleep, false) do
      :ok
    else
      Process.sleep(ms)
    end
  end
end

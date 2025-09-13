defmodule Http do
  @recv_timeout 5 * 60 * 1000

  @max_retries 10
  @base_backoff 100
  @backoff_cap 10_000

  @type url :: String.t()
  @type headers :: list({String.t(), String.t()})
  @type payload :: map()
  @type options :: keyword()

  @type http_status :: integer()
  @type http_error :: {:http_error, {http_status, String.t()}}
  @type transport_error :: {:transport_error, any()}
  @type success :: {:ok, map()}
  @type response :: success | http_error | transport_error

  @doc """
  Sends a POST request with a JSON payload to the specified URL with the given
  headers. Returns a tuple with the response status and body, or an error if
  the request fails.

  Retries up to #{@max_retries} times on 5xx HTTP responses and on select
  transient transport errors using exponential backoff with jitter.
  """
  @spec post_json(url(), headers(), payload()) :: response()
  def post_json(url, headers, payload) do
    with {:ok, body} <- Jason.encode(payload) do
      do_post_json(url, headers, body, 1)
    else
      {:error, _} -> {:transport_error, :invalid_json_response}
    end
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp do_post_json(url, headers, body, attempt) when attempt <= @max_retries do
    options = [
      recv_timeout: @recv_timeout,
      hackney_options: [pool: HttpPool.get()]
    ]

    HTTPoison.post(url, body, headers, options)
    |> case do
      {:ok, %{status_code: 200, body: json}} ->
        Jason.decode(json)

      {:ok, %{status_code: status_code, body: resp_body}} ->
        if retryable_http_status?(status_code) and attempt < @max_retries do
          delay = backoff_delay(attempt)

          UI.warn("[http] 50x response", """
          POST:     #{url}
          HTTP:     #{status_code}
          Attempt:  #{attempt}/#{@max_retries}
          Retry in: #{delay} ms
          """)

          maybe_sleep(delay)
          do_post_json(url, headers, body, attempt + 1)
        else
          {:http_error, {status_code, resp_body}}
        end

      {:error, %HTTPoison.Error{reason: reason}} ->
        if retryable_transport_reason?(reason) and attempt < @max_retries do
          delay = backoff_delay(attempt)

          UI.warn("[http] transport error", """
          POST:     #{url}
          Attempt:  #{attempt}/#{@max_retries}
          Retry in: #{delay} ms
          Reason:

          #{inspect(reason, pretty: true)}
          """)

          maybe_sleep(delay)
          do_post_json(url, headers, body, attempt + 1)
        else
          {:transport_error, reason}
        end
    end
  end

  defp do_post_json(url, headers, body, attempt) when attempt > @max_retries do
    # This clause should rarely be hit because the guards above stop at max-1,
    # but keep it for completeness. Perform one last attempt without retry.
    options = [
      recv_timeout: @recv_timeout,
      hackney_options: [pool: HttpPool.get()]
    ]

    HTTPoison.post(url, body, headers, options)
    |> case do
      {:ok, %{status_code: 200, body: json}} ->
        Jason.decode(json)

      {:ok, %{status_code: status_code, body: resp_body}} ->
        {:http_error, {status_code, resp_body}}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:transport_error, reason}
    end
  end

  defp retryable_http_status?(status) when is_integer(status), do: status >= 500 and status < 600

  defp retryable_transport_reason?(reason) do
    case reason do
      :timeout -> true
      :closed -> true
      :connect_timeout -> true
      :econnrefused -> true
      :nxdomain -> true
      :enetdown -> true
      :ehostunreach -> true
      {:tls_alert, _} -> true
      {:closed, _} -> true
      {:ssl, _} -> true
      _ -> false
    end
  end

  defp backoff_delay(attempt) when attempt >= 1 do
    # Exponential backoff with jitter (+/- 20%), capped at @backoff_cap
    base = trunc(min(@backoff_cap, @base_backoff * :math.pow(2, attempt - 1)))

    # Jitter factor between 0.8 and 1.2
    factor = 0.8 + :rand.uniform() * 0.4
    delay = round(base * factor)

    if delay < 1, do: 1, else: delay
  end

  defp maybe_sleep(ms) do
    if Application.get_env(:fnord, :http_retry_skip_sleep, false) do
      :ok
    else
      Process.sleep(ms)
    end
  end
end

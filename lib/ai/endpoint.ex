defmodule AI.Endpoint do
  @moduledoc """
  API endpoint abstraction.

  This behaviour centralizes HTTP JSON POST calls via `Http.post_json/3` and
  applies provider-agnostic retry/backoff. Provider endpoint modules implement
  `endpoint_path/0` and a small error classifier that inspects the raw HTTP/transport
  outcome and returns a normalized decision (`:ok`, `{:retry, reason, wait_ms}` or
  `{:fail, reason, human}`), allowing provider-specific error shapes (e.g.,
  OpenAI, Venice, Cloudflare plaintext) to be handled without leaking details
  into this module.

  Callers implement `endpoint_path/0` and then call `AI.Endpoint.post_json/3`.
  """

  @type headers :: list({String.t(), String.t()})
  @type payload :: map()

  @type http_status :: integer()
  @type http_error :: {:http_error, {http_status, String.t()}}
  @type transport_error :: {:transport_error, any()}

  @type success :: {:ok, %{body: map(), headers: headers(), status: http_status()}}
  @type response :: success | http_error | transport_error

  @type endpoint :: module()

  @retry_limit 3
  @backoff_base_ms 100
  @backoff_cap_ms 10_000

  # Hard ceiling on a single retry's wait. Any provider hint (usage
  # tracker, classifier suggestion) is clamped to this so a malformed
  # or misinterpreted value cannot wedge the harness via an unbounded
  # `Process.sleep`. 30s comfortably covers typical rate-limit reset
  # windows while keeping the worst case bounded; the backoff schedule
  # itself caps lower (`@backoff_cap_ms`) so this only ever fires when
  # an external hint goes haywire.
  @wait_ceiling_ms 30_000

  # Heartbeat interval for in-flight completions. The HTTP layer below
  # doesn't surface progress, and hackney's recv_timeout resets per
  # received chunk - so a slow-to-respond model can keep us blocked
  # silently for arbitrary lengths of time. A periodic info log makes
  # the wait visible without changing behavior.
  @heartbeat_interval_ms 30_000

  # ----------------------------------------------------------------------------
  # Behaviour Callbacks
  # ----------------------------------------------------------------------------
  @callback endpoint_path() :: String.t()

  @doc """
  Classify a non-success HTTP/transport result.

  This callback receives either an HTTP status + body (for HTTP errors) or a
  transport reason (for transport errors). Providers should return one of:
  - `:ok`                            — no retry; Endpoint returns the original result
  - `{:retry, reason, wait_ms | nil}`— retry; optional provider-suggested delay (ms)
  - `{:fail, reason, human}`         — stop retrying; human-friendly message for logs

  `headers` is currently `nil` for error cases as the lower-level HTTP client
  does not expose them. This can be extended in the future without breaking
  existing implementations.
  """
  @callback endpoint_error_classify(
              status :: integer | nil,
              body :: binary | nil,
              headers :: list | nil,
              transport_reason :: term | nil
            ) ::
              :ok
              | {:retry, reason :: atom, wait_ms :: non_neg_integer | nil}
              | {:fail, reason :: atom, human :: binary}

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
    do_post_json(endpoint_module, url, headers, payload, 1)
  end

  defp do_post_json(endpoint_module, url, headers, payload, attempt) do
    model = model_from_payload(payload)
    result = post_with_heartbeat(url, headers, payload, model)
    Store.APIUsage.record_for_model(model, result)

    case result do
      {:ok, %{body: _body} = payload} ->
        Services.BgIndexingControl.note_success(model)
        {:ok, payload}

      {:http_error, {status, body}} ->
        classify =
          if function_exported?(endpoint_module, :endpoint_error_classify, 4) do
            endpoint_module.endpoint_error_classify(status, body, nil, nil)
          else
            default_error_classify({:http_error, {status, body}}, nil)
          end

        handle_classification(
          classify,
          endpoint_module,
          url,
          headers,
          payload,
          attempt,
          model,
          {:http_error, {status, body}}
        )

      {:transport_error, reason} ->
        classify =
          if function_exported?(endpoint_module, :endpoint_error_classify, 4) do
            endpoint_module.endpoint_error_classify(nil, nil, nil, reason)
          else
            default_error_classify(nil, reason)
          end

        handle_classification(
          classify,
          endpoint_module,
          url,
          headers,
          payload,
          attempt,
          model,
          {:transport_error, reason}
        )
    end
  end

  defp handle_classification(
         classify,
         endpoint_module,
         url,
         headers,
         payload,
         attempt,
         model,
         original_result
       ) do
    case classify do
      {:retry, _reason, wait_ms} ->
        if attempt < retry_limit() do
          Services.BgIndexingControl.note_throttle(model)

          delay =
            [wait_ms, usage_wait_ms(model), backoff_delay_ms(attempt)]
            |> Enum.reject(&is_nil/1)
            |> Enum.max()
            |> min(@wait_ceiling_ms)

          UI.warn(
            "[AI.Endpoint] Retrying, model=#{inspect(model)}, attempt #{attempt}/#{retry_limit()}, retrying in #{Util.format_duration_ms(delay)}"
          )

          maybe_sleep(delay)
          do_post_json(endpoint_module, url, headers, payload, attempt + 1)
        else
          original_result
        end

      _ ->
        original_result
    end
  end

  # Run `Http.post_json/3` in a supervised task and emit a periodic
  # heartbeat log while it's in flight. The heartbeat is informational
  # only - if the task crashes we surface the original exit so the
  # caller's retry/error handling stays in control.
  #
  # In tests (`:http_retry_skip_sleep` set), bypass the task wrapper
  # entirely. Tests routinely use the parent process's dictionary to
  # track mocked HTTPoison call counts; spawning a child task isolates
  # those writes and breaks call-count assertions. Production never
  # sets that flag, so the heartbeat is always live there.
  @spec post_with_heartbeat(String.t(), Http.headers(), Http.payload(), binary | nil) ::
          Http.post_response()
  defp post_with_heartbeat(url, headers, payload, model) do
    if Services.Globals.get_env(:fnord, :http_retry_skip_sleep, false) do
      Http.post_json(url, headers, payload)
    else
      parent_pool = HttpPool.get()

      task =
        Task.async(fn ->
          HttpPool.set(parent_pool)
          Http.post_json(url, headers, payload)
        end)

      await_with_heartbeat(task, model, 0)
    end
  end

  defp await_with_heartbeat(task, model, elapsed_ms) do
    case Task.yield(task, @heartbeat_interval_ms) do
      nil ->
        elapsed = elapsed_ms + @heartbeat_interval_ms

        UI.info(
          "[AI.Endpoint] Still waiting on #{inspect(model)} (#{Util.format_duration_ms(elapsed)} elapsed)"
        )

        await_with_heartbeat(task, model, elapsed)

      {:ok, result} ->
        result

      {:exit, reason} ->
        # The wrapped Http.post_json itself returns tagged tuples for
        # all expected failure modes; an exit here is something
        # genuinely unexpected (process kill, etc.). Re-raise so the
        # caller sees it rather than silently treating it as a
        # transport error.
        exit(reason)
    end
  end

  @spec default_error_classify({:http_error, {http_status, String.t()}} | nil, any()) ::
          :ok
          | {:retry, reason :: atom, wait_ms :: non_neg_integer | nil}
          | {:fail, reason :: atom, human :: binary}
  defp default_error_classify({:http_error, {status, body}}, _transport_reason) do
    cond do
      # Retry throttled 429s by default when the body indicates OpenAI-style throttling
      default_throttled?(status) and default_throttle_code?(body) ->
        {:retry, :throttled, default_try_again_ms(body)}

      status >= 500 ->
        {:retry, :server_error, nil}

      true ->
        :ok
    end
  end

  defp default_error_classify(nil, _transport_reason) do
    # By default, do not retry transport errors; pass them through unchanged
    :ok
  end

  @spec default_throttled?(integer() | nil) :: boolean()
  defp default_throttled?(429), do: true
  defp default_throttled?(_), do: false

  @spec default_throttle_code?(binary()) :: boolean()
  defp default_throttle_code?(body) do
    with {:ok, %{"error" => %{"code" => code}}} <- Jason.decode(body) do
      code in ["rate_limit_exceeded", "rate_limit"]
    else
      _ -> false
    end
  end

  @spec default_try_again_ms(binary()) :: non_neg_integer | nil
  defp default_try_again_ms(body) do
    case Regex.run(~r/try\s+again\s+in\s+(\d+)ms/i, body) do
      [_, ms] -> max(1, String.to_integer(ms))
      _ -> nil
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

  # Powers-of-10 backoff with jitter (+/- 20%). At base 100ms the
  # schedule lands at ~100ms, ~1s, ~10s for attempts 1..3, capped at
  # `@backoff_cap_ms`. This shape is deliberate: the per-attempt order
  # of magnitude shifts by 1 each time, giving a transient overload a
  # handful of fast retries while the third attempt waits long enough
  # for sustained backpressure to clear.
  defp backoff_delay_ms(attempt) when attempt >= 1 do
    jitter = 0.8 + :rand.uniform() * 0.4

    @backoff_cap_ms
    |> min(@backoff_base_ms * :math.pow(10, attempt - 1))
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

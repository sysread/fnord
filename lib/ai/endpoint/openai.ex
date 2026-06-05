defmodule AI.Endpoint.OpenAI do
  @moduledoc """
  OpenAI-specific endpoint implementation.

  Provides the endpoint path and error classification used by AI.Endpoint's
  centralized retry/backoff logic.
  """

  @behaviour AI.Endpoint

  @base_url "https://api.openai.com"

  @impl AI.Endpoint
  @spec endpoint_path() :: String.t()
  def endpoint_path, do: "#{@base_url}/v1/responses"

  @doc """
  Provider-specific error classifier for OpenAI/Cloudflare style responses.
  See `c:AI.Endpoint.endpoint_error_classify/4` for contract details.
  """
  @impl AI.Endpoint
  @spec endpoint_error_classify(integer | nil, binary | nil, list | nil, term | nil) ::
          :ok | {:retry, atom, non_neg_integer | nil} | {:fail, atom, binary}
  def endpoint_error_classify(status, body, _headers, transport_reason) do
    # Body is always a binary here when status is set: the HTTP client
    # (HTTPoison via Http.post_json) returns binary bodies for every non-2xx
    # response. The `is_binary(b)` guards on the 429 clause are paranoia,
    # not feature gating - if a non-binary body somehow appeared they'd
    # fall through to the catch-all `:ok` (no retry), which is the right
    # safe default for "we don't know what this is."
    case {status, body, transport_reason} do
      {nil, nil, :timeout} ->
        {:retry, :network_glitch, nil}

      {nil, nil, :closed} ->
        {:retry, :network_glitch, nil}

      {nil, nil, {:tls_alert, _}} ->
        {:retry, :network_glitch, nil}

      {nil, nil, {:ssl, _}} ->
        {:retry, :network_glitch, nil}

      {429, b, _} when is_binary(b) ->
        cond do
          throttled_json?(b) -> {:retry, :throttled, parse_try_again_ms(b)}
          cloudflare_plaintext?(b) -> {:retry, :intermediary, parse_try_again_ms(b) || 300}
          true -> {:retry, :throttled, nil}
        end

      {s, _b, _} when is_integer(s) and s >= 500 and s < 600 ->
        {:retry, :server_error, nil}

      {401, _b, _} ->
        {:fail, :unauthorized, "Unauthorized"}

      {403, _b, _} ->
        {:fail, :forbidden, "Forbidden"}

      _ ->
        :ok
    end
  end

  defp throttled_json?(body) do
    case SafeJson.decode(body) do
      {:ok, %{"error" => %{"code" => code}}} when code in ["rate_limit_exceeded", "rate_limit"] ->
        true

      _ ->
        false
    end
  end

  defp cloudflare_plaintext?(body) when is_binary(body) do
    Regex.match?(~r/cloudflare|please\s+try\s+again/i, body)
  end

  # OpenAI's rate-limit body uses either "try again in 250ms" or "try again
  # in 1.566s" depending on the wait. Both may carry a decimal point. The
  # retry scheduler is in ms.
  defp parse_try_again_ms(body) when is_binary(body) do
    cond do
      match = Regex.run(~r/try\s+again\s+in\s+(\d+(?:\.\d+)?)\s*ms/i, body) ->
        [_, ms_str] = match
        max(1, ms_str |> parse_number() |> round())

      match = Regex.run(~r/try\s+again\s+in\s+(\d+(?:\.\d+)?)\s*s/i, body) ->
        [_, s_str] = match
        max(1, (parse_number(s_str) * 1000) |> round())

      true ->
        nil
    end
  end

  defp parse_number(str) do
    case Float.parse(str) do
      {n, _} -> n
      :error -> 0.0
    end
  end
end

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
  def endpoint_path, do: "#{@base_url}/v1/chat/completions"

  @doc """
  Provider-specific error classifier for OpenAI/Cloudflare style responses.
  See `AI.Endpoint.endpoint_error_classify/4` for contract details.
  """
  @impl AI.Endpoint
  @spec endpoint_error_classify(integer | nil, binary | nil, list | nil, term | nil) ::
          :ok | {:retry, atom, non_neg_integer | nil} | {:fail, atom, binary}
  def endpoint_error_classify(status, body, _headers, transport_reason) do
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

  defp parse_try_again_ms(body) when is_binary(body) do
    case Regex.run(~r/try\s+again\s+in\s+(\d+)ms/i, body) do
      [_, ms] -> max(1, String.to_integer(ms))
      _ -> nil
    end
  end
end

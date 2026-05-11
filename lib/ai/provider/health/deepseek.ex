defmodule AI.Provider.Health.DeepSeek do
  @moduledoc """
  DeepSeek implementation of the `AI.Provider.Health` behaviour.

  Verifies the API key by making a GET request to `/models` with
  Bearer auth. A 200 response with a parseable `data` array is
  considered healthy.

  Mirrors the OpenAI/Inception health check; DeepSeek is OpenAI-API-
  compatible at this surface. Error messages surface DeepSeek by name
  so `fnord config provider check` against the wrong provider doesn't
  read as "OpenAI is broken."
  """

  @behaviour AI.Provider.Health

  @models_url "https://api.deepseek.com/models"

  @impl AI.Provider.Health
  def check() do
    with {:ok, key} <- safe_api_key() do
      get_models(key)
    end
  end

  defp safe_api_key() do
    try do
      {:ok, AI.Provider.RequestBuilder.DeepSeek.api_key!()}
    rescue
      e in RuntimeError ->
        {:error, :missing_api_key, Exception.message(e)}
    end
  end

  defp get_models(key) do
    headers = AI.Provider.RequestBuilder.DeepSeek.build_headers(key)

    case Http.get(@models_url, headers) do
      {:ok, body} ->
        parse_models_body(body)

      {:http_error, {401, _}} ->
        {:error, :unauthorized, "DeepSeek rejected the API key (HTTP 401)."}

      {:http_error, {status, body}} ->
        {:error, :other, "DeepSeek returned HTTP #{status}: #{trim(body)}"}

      {:transport_error, reason} ->
        {:error, :unreachable, "Could not reach DeepSeek: #{inspect(reason)}"}
    end
  end

  defp parse_models_body(body) do
    case SafeJson.decode(body) do
      {:ok, %{"data" => models}} when is_list(models) ->
        {:ok, %{model_count: length(models)}}

      _ ->
        {:error, :other, "DeepSeek returned a 200 with an unexpected body shape."}
    end
  end

  defp trim(body) when is_binary(body) do
    body |> String.slice(0, 200) |> String.trim()
  end
end

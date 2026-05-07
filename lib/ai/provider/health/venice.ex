defmodule AI.Provider.Health.Venice do
  @moduledoc """
  Venice implementation of the `AI.Provider.Health` behaviour.

  Verifies the API key by making a GET request to `/api/v1/models` with
  Bearer auth. A 200 response with a parseable `data` array is
  considered healthy; counts the models for the info field.

  ## Why we hit /models rather than /chat/completions

  `/chat/completions` is a POST that costs tokens. `/models` is a free
  GET that requires the same Bearer auth. The check is for "is the key
  good?" - the cheaper read endpoint is the right tool.
  """

  @behaviour AI.Provider.Health

  @models_url "https://api.venice.ai/api/v1/models"

  @impl AI.Provider.Health
  def check() do
    with {:ok, key} <- safe_api_key() do
      get_models(key)
    end
  end

  defp safe_api_key() do
    try do
      {:ok, AI.Provider.RequestBuilder.Venice.api_key!()}
    rescue
      e in RuntimeError ->
        {:error, :missing_api_key, Exception.message(e)}
    end
  end

  defp get_models(key) do
    headers = AI.Provider.RequestBuilder.Venice.build_headers(key)

    case Http.get(@models_url, headers) do
      {:ok, body} ->
        parse_models_body(body)

      {:http_error, {401, _, _}} ->
        {:error, :unauthorized, "Venice rejected the API key (HTTP 401)."}

      {:http_error, {402, _, _}} ->
        {:error, :unauthorized,
         "Venice reports insufficient balance (HTTP 402). The API key is " <>
           "valid but the wallet needs topping up."}

      {:http_error, {status, body, _}} ->
        {:error, :other, "Venice returned HTTP #{status}: #{trim(body)}"}

      {:transport_error, reason} ->
        {:error, :unreachable, "Could not reach Venice: #{inspect(reason)}"}
    end
  end

  defp parse_models_body(body) do
    case SafeJson.decode(body) do
      {:ok, %{"data" => models}} when is_list(models) ->
        {:ok, %{model_count: length(models)}}

      _ ->
        {:error, :other, "Venice returned a 200 with an unexpected body shape."}
    end
  end

  defp trim(body) when is_binary(body) do
    body |> String.slice(0, 200) |> String.trim()
  end
end

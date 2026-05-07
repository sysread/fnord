defmodule AI.Provider.Health.OpenAI do
  @moduledoc """
  OpenAI implementation of the `AI.Provider.Health` behaviour.

  Verifies the API key by making a GET request to `/v1/models` with
  Bearer auth. A 200 response with a parseable `data` array is
  considered healthy; counts the models for the info field.
  """

  @behaviour AI.Provider.Health

  @models_url "https://api.openai.com/v1/models"

  @impl AI.Provider.Health
  def check() do
    with {:ok, key} <- safe_api_key() do
      get_models(key)
    end
  end

  # Capture the api_key!/0 raise as a structured error - the behaviour
  # contract says we cannot let it escape.
  defp safe_api_key() do
    try do
      {:ok, AI.Provider.RequestBuilder.OpenAI.api_key!()}
    rescue
      e in RuntimeError ->
        {:error, :missing_api_key, Exception.message(e)}
    end
  end

  defp get_models(key) do
    headers = AI.Provider.RequestBuilder.OpenAI.build_headers(key)

    case Http.get(@models_url, headers) do
      {:ok, body} ->
        parse_models_body(body)

      {:http_error, {401, _, _}} ->
        {:error, :unauthorized, "OpenAI rejected the API key (HTTP 401)."}

      {:http_error, {status, body, _}} ->
        {:error, :other, "OpenAI returned HTTP #{status}: #{trim(body)}"}

      {:transport_error, reason} ->
        {:error, :unreachable, "Could not reach OpenAI: #{inspect(reason)}"}
    end
  end

  defp parse_models_body(body) do
    case SafeJson.decode(body) do
      {:ok, %{"data" => models}} when is_list(models) ->
        {:ok, %{model_count: length(models)}}

      _ ->
        {:error, :other, "OpenAI returned a 200 with an unexpected body shape."}
    end
  end

  defp trim(body) when is_binary(body) do
    body |> String.slice(0, 200) |> String.trim()
  end
end

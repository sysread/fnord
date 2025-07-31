defmodule Http do
  @recv_timeout 5 * 60 * 1000

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
  """
  @spec post_json(url(), headers(), payload()) :: response()
  def post_json(url, headers, payload) do
    options = [
      recv_timeout: @recv_timeout,
      hackney_options: [pool: :ai_api]
    ]

    with {:ok, body} <- Jason.encode(payload) do
      HTTPoison.post(url, body, headers, options)
      |> case do
        {:ok, %{status_code: 200, body: json}} ->
          Jason.decode(json)

        {:ok, %{status_code: status_code, body: body}} ->
          {:http_error, {status_code, body}}

        {:error, %HTTPoison.Error{reason: reason}} ->
          {:transport_error, reason}
      end
    else
      {:error, %Jason.EncodeError{}} -> {:transport_error, :invalid_json_response}
    end
  end
end

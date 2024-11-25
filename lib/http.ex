defmodule Http do
  @json_headers [{"Content-Type", "application/json"}]

  def post_json(url, headers, payload, options \\ []) do
    with {:ok, body} <- Jason.encode(payload) do
      HTTPoison.post(url, body, @json_headers ++ headers, options)
      |> case do
        {:ok, %{status_code: 200, body: json}} -> Jason.decode(json)
        {:ok, %{status_code: status_code, body: body}} -> {:error, {status_code, body}}
        {:error, %HTTPoison.Error{reason: reason}} -> {:error, reason}
      end
    end
  end
end

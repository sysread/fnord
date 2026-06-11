defmodule AI.EndpointCatchAllTest do
  use Fnord.TestCase, async: true

  defmodule DummyEndpoint do
    @behaviour AI.Endpoint

    @impl AI.Endpoint
    def endpoint_path, do: "http://example.com/endpoint"

    @impl AI.Endpoint
    def endpoint_error_classify(_status, _body, _headers, _transport_reason), do: :ok
  end

  test "passthrough transport_error tuple" do
    # :closed is a retryable transport reason, so Http exhausts its retry
    # budget (sleeps are skipped by TestCase) before surfacing the error;
    # the endpoint's catch-all classifier must pass the tuple through as-is.
    stub(Http.Client.Mock, :post, fn _url, _body, _headers, _opts ->
      {:error, %HTTPoison.Error{reason: :closed}}
    end)

    result = AI.Endpoint.post_json(DummyEndpoint, [], %{})
    assert result == {:transport_error, :closed}
  end
end

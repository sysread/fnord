defmodule AI.EndpointCatchAllTest do
  use ExUnit.Case

  setup do
    # Stub Http.post_json/3 to return a transport_error tuple
    :ok = :meck.new(Http, [:no_link, :passthrough])
    :ok = :meck.new(Store.APIUsage, [:no_link, :passthrough])

    on_exit(fn ->
      :meck.unload(Http)
      :meck.unload(Store.APIUsage)
    end)

    :ok
  end

  defmodule DummyEndpoint do
    @behaviour AI.Endpoint

    @impl AI.Endpoint
    def endpoint_path, do: "http://example.com/endpoint"

    @impl AI.Endpoint
    def endpoint_error_classify(_status, _body, _headers, _transport_reason), do: :ok
  end

  test "passthrough transport_error tuple" do
    :meck.expect(Http, :post_json, fn _url, _headers, _payload ->
      {:transport_error, :closed}
    end)

    result = AI.Endpoint.post_json(DummyEndpoint, [], %{})
    assert result == {:transport_error, :closed}
  end
end

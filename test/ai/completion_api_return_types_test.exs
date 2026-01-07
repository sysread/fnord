defmodule AI.CompletionAPITransportErrorTest do
  use ExUnit.Case
  alias AI.Model

  setup do
    # Stub the AI.Endpoint.post_json/3 to simulate transport errors
    :ok = :meck.new(AI.Endpoint, [:no_link, :passthrough])
    on_exit(fn -> :meck.unload(AI.Endpoint) end)
    :ok
  end

  test "maps transport_error closed to {:error, \"Connection closed\"}" do
    model = %Model{model: "test-model", context: 0, reasoning: :medium}

    # Expect post_json to be called for AI.CompletionAPI and return transport error
    :meck.expect(AI.Endpoint, :post_json, fn endpoint_mod, _headers, _payload ->
      assert endpoint_mod == AI.CompletionAPI
      {:transport_error, :closed}
    end)

    result = AI.CompletionAPI.get(model, [], nil, nil, false)
    assert result == {:error, "Connection closed"}
  end
end

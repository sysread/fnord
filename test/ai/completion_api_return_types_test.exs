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

  test "includes verbosity in payload when verbosity is set" do
    # Expect post_json to capture and assert verbosity in payload
    :meck.expect(AI.Endpoint, :post_json, fn endpoint_mod, _headers, payload ->
      assert endpoint_mod == AI.CompletionAPI
      assert payload["verbosity"] == "detailed"
      {:ok, %{"choices" => []}}
    end)

    base_model = %Model{model: "test-model", context: 0, reasoning: :medium}
    model = Model.with_verbosity(base_model, :detailed)
    _result = AI.CompletionAPI.get(model, [], nil, nil, false)
  end

  test "does not include verbosity in payload when verbosity is nil" do
    # Expect post_json to capture and assert no verbosity in payload
    :meck.expect(AI.Endpoint, :post_json, fn endpoint_mod, _headers, payload ->
      assert endpoint_mod == AI.CompletionAPI
      refute Map.has_key?(payload, "verbosity")
      {:ok, %{"choices" => []}}
    end)

    model = %Model{model: "test-model", context: 0, reasoning: :medium}
    _result = AI.CompletionAPI.get(model, [], nil, nil, false)
  end
end

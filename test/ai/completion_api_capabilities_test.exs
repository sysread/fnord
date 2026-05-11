defmodule AI.CompletionAPICapabilitiesTest do
  @moduledoc """
  Tests that capability flags on `AI.Model.t` correctly gate which optional
  fields are emitted in the chat-completion request payload.

  These tests stub `AI.Endpoint.post_json/3` so the assertions can inspect
  the payload before it leaves the BEAM. The intent is to lock in the
  contract that:

    - `reasoning_effort` is emitted only when `model.supports_reasoning`
      is true AND `model.reasoning` maps to a known wire string
    - `web_search_options` is emitted only when `model.supports_web_search`
      is true AND the caller passed `web_search?: true`
    - Asking for `web_search?: true` against a non-web-search model raises
      at the call site rather than producing a confusing API error
  """

  use Fnord.TestCase, async: false
  alias AI.Model

  setup do
    :ok = :meck.new(AI.Endpoint, [:no_link, :passthrough])
    on_exit(fn -> :meck.unload(AI.Endpoint) end)
    # The real Util.Env reads from the process environment, not Globals,
    # so the API key has to be a real env var to satisfy `get_api_key!`.
    Util.Env.put_env("FNORD_OPENAI_API_KEY", "test-key")
    on_exit(fn -> Util.Env.put_env("FNORD_OPENAI_API_KEY", "") end)
    :ok
  end

  describe "reasoning_effort emission" do
    test "is emitted when model supports reasoning and level is :low/:medium/:high" do
      :meck.expect(AI.Endpoint, :post_json, fn _mod, _headers, payload ->
        assert payload[:reasoning_effort] == "high"
        {:ok, %{"choices" => []}}
      end)

      model = Model.new("rcap-on", 1024, :high, supports_reasoning: true)
      AI.CompletionAPI.get(model, [], nil, nil, false)
    end

    test "is dropped when model does not support reasoning, even if level is :high" do
      :meck.expect(AI.Endpoint, :post_json, fn _mod, _headers, payload ->
        refute Map.has_key?(payload, :reasoning_effort)
        {:ok, %{"choices" => []}}
      end)

      model = Model.new("rcap-off", 1024, :high, supports_reasoning: false)
      AI.CompletionAPI.get(model, [], nil, nil, false)
    end

    test "is dropped when level is unmapped (e.g. :none)" do
      :meck.expect(AI.Endpoint, :post_json, fn _mod, _headers, payload ->
        refute Map.has_key?(payload, :reasoning_effort)
        {:ok, %{"choices" => []}}
      end)

      model = Model.new("rcap-on-none", 1024, :none, supports_reasoning: true)
      AI.CompletionAPI.get(model, [], nil, nil, false)
    end
  end

  describe "web_search_options emission" do
    test "is emitted when web_search? is true and model supports it" do
      :meck.expect(AI.Endpoint, :post_json, fn _mod, _headers, payload ->
        assert payload[:web_search_options] == %{}
        {:ok, %{"choices" => []}}
      end)

      model = Model.new("websearch-cap", 1024, :none, supports_web_search: true)
      AI.CompletionAPI.get(model, [], nil, nil, true)
    end

    test "is omitted when web_search? is false" do
      :meck.expect(AI.Endpoint, :post_json, fn _mod, _headers, payload ->
        refute Map.has_key?(payload, :web_search_options)
        {:ok, %{"choices" => []}}
      end)

      model = Model.new("websearch-cap-off-call", 1024, :none, supports_web_search: true)
      AI.CompletionAPI.get(model, [], nil, nil, false)
    end

    test "raises when web_search? is true but model does not support web search" do
      # The post_json stub should never be invoked - the guard fires first.
      :meck.expect(AI.Endpoint, :post_json, fn _mod, _headers, _payload ->
        flunk("post_json should not be called when capability check fails")
      end)

      model = Model.new("no-websearch", 1024, :none, supports_web_search: false)

      assert_raise ArgumentError, ~r/does not support web search/, fn ->
        AI.CompletionAPI.get(model, [], nil, nil, true)
      end
    end
  end
end

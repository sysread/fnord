defmodule AI.Provider.RequestBuilder.InceptionTest do
  @moduledoc """
  Behavioral tests for the Inception Labs request-builder. Mirrors the
  OpenAI test shape; Inception is OpenAI-API-compatible at the chat-
  completions surface.
  """

  use Fnord.TestCase, async: false
  alias AI.Model
  alias AI.Provider.RequestBuilder.Inception, as: Builder

  describe "system_role/0" do
    test "returns \"system\" - Inception follows the legacy role convention" do
      assert Builder.system_role() == "system"
    end
  end

  describe "api_key!/0" do
    setup do
      orig_fnord = System.get_env("FNORD_INCEPTION_API_KEY")
      orig_inception = System.get_env("INCEPTION_API_KEY")

      System.delete_env("FNORD_INCEPTION_API_KEY")
      System.delete_env("INCEPTION_API_KEY")

      on_exit(fn ->
        if orig_fnord, do: System.put_env("FNORD_INCEPTION_API_KEY", orig_fnord)
        if orig_inception, do: System.put_env("INCEPTION_API_KEY", orig_inception)
      end)

      :ok
    end

    test "raises with both env-var names in the message when neither is set" do
      assert_raise RuntimeError, ~r/FNORD_INCEPTION_API_KEY or INCEPTION_API_KEY/, fn ->
        Builder.api_key!()
      end
    end

    test "fnord-prefixed name takes precedence" do
      System.put_env("FNORD_INCEPTION_API_KEY", "fk")
      System.put_env("INCEPTION_API_KEY", "ok")
      assert Builder.api_key!() == "fk"
    end

    test "falls back to upstream-canonical name when fnord-prefixed is unset" do
      System.put_env("INCEPTION_API_KEY", "ok")
      assert Builder.api_key!() == "ok"
    end
  end

  describe "build_headers/1" do
    test "produces Bearer auth + JSON content-type" do
      headers = Builder.build_headers("k1")
      assert {"Authorization", "Bearer k1"} in headers
      assert {"Content-Type", "application/json"} in headers
    end
  end

  describe "build_payload/6" do
    test "minimal payload contains model, default response_format, untouched messages" do
      model = Model.new("m", 1024)
      payload = Builder.build_payload(model, [], nil, nil, false, nil)
      assert payload[:model] == "m"
      assert payload[:messages] == []
      assert payload[:response_format] == %{type: "text"}
      # Inception does not accept reasoning_effort, verbosity, or
      # web_search_options - the builder must NOT emit them.
      refute Map.has_key?(payload, :tools)
      refute Map.has_key?(payload, :reasoning_effort)
      refute Map.has_key?(payload, :verbosity)
      refute Map.has_key?(payload, :web_search_options)
      refute Map.has_key?(payload, :text)
    end

    test "tools field present when tools are passed" do
      model = Model.new("m", 1024)
      tools = [%{type: "function", function: %{name: "x"}}]
      payload = Builder.build_payload(model, [], tools, nil, false, nil)
      assert payload[:tools] == tools
    end

    test "honors caller-supplied response_format verbatim" do
      model = Model.new("m", 1024)
      rf = %{type: "json_schema", json_schema: %{name: "S", schema: %{}}}
      payload = Builder.build_payload(model, [], nil, rf, false, nil)
      assert payload[:response_format] == rf
    end

    test "verbosity is silently dropped (Inception doesn't accept it)" do
      model = Model.new("m", 1024)
      payload = Builder.build_payload(model, [], nil, nil, false, "high")
      refute Map.has_key?(payload, :verbosity)
    end

    test "raises when web_search? is true (Inception has no web-search-capable model)" do
      model = Model.new("m", 1024, :none, supports_web_search: false)

      assert_raise ArgumentError, ~r/no web-search-capable model/, fn ->
        Builder.build_payload(model, [], nil, nil, true, nil)
      end
    end

    test "no reasoning_effort field even when model.reasoning is set" do
      # mercury-2 is not reasoning-capable; the builder should never
      # emit reasoning_effort regardless of the model.reasoning value.
      # The capability flag check is what gates emission - this test
      # locks that contract.
      model = Model.new("m", 1024, :high, supports_reasoning: false)
      payload = Builder.build_payload(model, [], nil, nil, false, nil)
      refute Map.has_key?(payload, :reasoning_effort)
    end
  end
end

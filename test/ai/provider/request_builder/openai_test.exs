defmodule AI.Provider.RequestBuilder.OpenAITest do
  @moduledoc """
  Behavioral tests for the OpenAI request-builder.

  These exercise the same payload-shape contract that
  `AI.CompletionAPICapabilitiesTest` covers from the orchestration side,
  but at the per-provider level so the contract is locked in without
  going through the HTTP layer at all.
  """

  use ExUnit.Case
  alias AI.Model
  alias AI.Provider.RequestBuilder.OpenAI, as: Builder

  describe "system_role/0" do
    test "returns \"developer\" - OpenAI's Responses-API-era convention" do
      assert Builder.system_role() == "developer"
    end
  end

  describe "api_key!/0" do
    setup do
      # Snapshot whatever the test harness already put in place, then
      # restore it on exit so we do not leak state to other tests. We
      # use System.delete_env in this block to truly unset (rather than
      # set-to-empty), since this suite's contract is what `api_key!`
      # does when the env vars are *unset*.
      orig_fnord = System.get_env("FNORD_OPENAI_API_KEY")
      orig_openai = System.get_env("OPENAI_API_KEY")

      System.delete_env("FNORD_OPENAI_API_KEY")
      System.delete_env("OPENAI_API_KEY")

      on_exit(fn ->
        if orig_fnord, do: System.put_env("FNORD_OPENAI_API_KEY", orig_fnord)
        if orig_openai, do: System.put_env("OPENAI_API_KEY", orig_openai)
      end)

      :ok
    end

    test "raises with a descriptive message when neither env var is set" do
      assert_raise RuntimeError, ~r/FNORD_OPENAI_API_KEY or OPENAI_API_KEY/, fn ->
        Builder.api_key!()
      end
    end

    test "returns FNORD_OPENAI_API_KEY when only it is set" do
      System.put_env("FNORD_OPENAI_API_KEY", "fk")
      assert Builder.api_key!() == "fk"
    end

    test "returns OPENAI_API_KEY when only it is set" do
      System.put_env("OPENAI_API_KEY", "ok")
      assert Builder.api_key!() == "ok"
    end

    test "fnord-prefixed name takes precedence" do
      System.put_env("FNORD_OPENAI_API_KEY", "fk")
      System.put_env("OPENAI_API_KEY", "ok")
      assert Builder.api_key!() == "fk"
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
    test "minimal payload contains model, messages, default response_format" do
      model = Model.new("m", 1024)
      payload = Builder.build_payload(model, [], nil, nil, false, nil)
      assert payload[:model] == "m"
      assert payload[:messages] == []
      assert payload[:response_format] == %{type: "text"}
      refute Map.has_key?(payload, :tools)
      refute Map.has_key?(payload, :reasoning_effort)
      refute Map.has_key?(payload, :web_search_options)
      refute Map.has_key?(payload, :verbosity)
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

    test "verbosity included when set" do
      model = Model.new("m", 1024)
      payload = Builder.build_payload(model, [], nil, nil, false, "high")
      assert payload[:verbosity] == "high"
    end

    test "reasoning_effort emitted only when capability flag is true" do
      m_on = Model.new("m", 1024, :high, supports_reasoning: true)
      m_off = Model.new("m", 1024, :high, supports_reasoning: false)

      assert Builder.build_payload(m_on, [], nil, nil, false, nil)[:reasoning_effort] == "high"
      refute Map.has_key?(Builder.build_payload(m_off, [], nil, nil, false, nil), :reasoning_effort)
    end

    test "web_search_options emitted only when capability flag is true and caller asks" do
      m_cap = Model.new("m", 1024, :none, supports_web_search: true)
      m_no = Model.new("m", 1024, :none, supports_web_search: false)

      # Capability + caller request
      assert Builder.build_payload(m_cap, [], nil, nil, true, nil)[:web_search_options] == %{}

      # Capability but caller did not ask
      refute Map.has_key?(
               Builder.build_payload(m_cap, [], nil, nil, false, nil),
               :web_search_options
             )

      # Caller asks against a non-capable model: raise
      assert_raise ArgumentError, ~r/does not support web search/, fn ->
        Builder.build_payload(m_no, [], nil, nil, true, nil)
      end
    end
  end
end

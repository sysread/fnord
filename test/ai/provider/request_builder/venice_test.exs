defmodule AI.Provider.RequestBuilder.VeniceTest do
  @moduledoc """
  Behavioral tests for the Venice request-builder.

  Locks in the venice_parameters shape for web-search requests, the
  reasoning_effort handling (including Venice-only `:xhigh` / `:max`
  levels), and the deliberate omission of verbosity.
  """

  use ExUnit.Case
  alias AI.Model
  alias AI.Provider.RequestBuilder.Venice, as: Builder

  describe "api_key!/0" do
    setup do
      orig_fnord = System.get_env("FNORD_VENICE_API_KEY")
      orig_venice = System.get_env("VENICE_API_KEY")

      System.delete_env("FNORD_VENICE_API_KEY")
      System.delete_env("VENICE_API_KEY")

      on_exit(fn ->
        if orig_fnord, do: System.put_env("FNORD_VENICE_API_KEY", orig_fnord)
        if orig_venice, do: System.put_env("VENICE_API_KEY", orig_venice)
      end)

      :ok
    end

    test "raises with both env-var names in the message when neither is set" do
      assert_raise RuntimeError, ~r/FNORD_VENICE_API_KEY or VENICE_API_KEY/, fn ->
        Builder.api_key!()
      end
    end

    test "fnord-prefixed name takes precedence" do
      System.put_env("FNORD_VENICE_API_KEY", "fk")
      System.put_env("VENICE_API_KEY", "vk")
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
    test "minimal payload contains model, messages, and default response_format" do
      model = Model.new("m", 1024)
      payload = Builder.build_payload(model, [], nil, nil, false, nil)
      assert payload[:model] == "m"
      assert payload[:messages] == []
      assert payload[:response_format] == %{type: "text"}
      refute Map.has_key?(payload, :tools)
      refute Map.has_key?(payload, :reasoning_effort)
      refute Map.has_key?(payload, :venice_parameters)
    end

    test "verbosity is silently dropped (Venice expresses it via text.verbosity, not honored today)" do
      model = Model.new("m", 1024)
      payload = Builder.build_payload(model, [], nil, nil, false, "high")
      refute Map.has_key?(payload, :verbosity)
    end

    test "tools field present when tools are passed" do
      model = Model.new("m", 1024)
      tools = [%{type: "function", function: %{name: "x"}}]
      payload = Builder.build_payload(model, [], tools, nil, false, nil)
      assert payload[:tools] == tools
    end

    test "reasoning_effort emitted only when capability flag is true" do
      m_on = Model.new("m", 1024, :high, supports_reasoning: true)
      m_off = Model.new("m", 1024, :high, supports_reasoning: false)

      assert Builder.build_payload(m_on, [], nil, nil, false, nil)[:reasoning_effort] == "high"
      refute Map.has_key?(Builder.build_payload(m_off, [], nil, nil, false, nil), :reasoning_effort)
    end

    test "Venice-only :xhigh and :max reasoning levels pass through verbatim" do
      m_xhigh = Model.new("m", 1024, :xhigh, supports_reasoning: true)
      m_max = Model.new("m", 1024, :max, supports_reasoning: true)

      assert Builder.build_payload(m_xhigh, [], nil, nil, false, nil)[:reasoning_effort] == "xhigh"
      assert Builder.build_payload(m_max, [], nil, nil, false, nil)[:reasoning_effort] == "max"
    end

    test ":none and :minimal levels emit corresponding wire strings on Venice" do
      m_none = Model.new("m", 1024, :none, supports_reasoning: true)
      m_minimal = Model.new("m", 1024, :minimal, supports_reasoning: true)

      assert Builder.build_payload(m_none, [], nil, nil, false, nil)[:reasoning_effort] == "none"

      assert Builder.build_payload(m_minimal, [], nil, nil, false, nil)[:reasoning_effort] ==
               "minimal"
    end

    test "venice_parameters set when web_search? is true and model supports it" do
      m_cap = Model.new("m", 1024, :none, supports_web_search: true)
      payload = Builder.build_payload(m_cap, [], nil, nil, true, nil)
      vp = payload[:venice_parameters]
      assert vp[:enable_web_search] == "on"
      assert vp[:enable_web_citations] == true
      assert vp[:strip_thinking_response] == true
    end

    test "venice_parameters omitted when web_search? is false" do
      m_cap = Model.new("m", 1024, :none, supports_web_search: true)
      refute Map.has_key?(Builder.build_payload(m_cap, [], nil, nil, false, nil), :venice_parameters)
    end

    test "raises when web_search? is true but the model lacks the capability" do
      m_no = Model.new("m", 1024, :none, supports_web_search: false)

      assert_raise ArgumentError, ~r/does not support web search/, fn ->
        Builder.build_payload(m_no, [], nil, nil, true, nil)
      end
    end
  end
end

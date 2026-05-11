defmodule AI.Provider.RequestBuilder.VeniceTest do
  @moduledoc """
  Behavioral tests for the Venice request-builder.

  Locks in the venice_parameters shape for web-search requests, the
  reasoning_effort handling (including Venice-only `:xhigh` / `:max`
  levels), and the deliberate omission of verbosity.
  """

  use Fnord.TestCase, async: false
  alias AI.Model
  alias AI.Provider.RequestBuilder.Venice, as: Builder

  describe "system_role/0" do
    test "returns \"system\" - Venice does not honor OpenAI's developer role" do
      assert Builder.system_role() == "system"
    end
  end

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
    setup do
      # The builder constructs system-style messages via `AI.Util.system_msg/1`,
      # which delegates role naming to `AI.Provider.system_role/0` -> the active
      # provider's request builder. Pin the provider to "venice" so the role
      # comes out as "system" rather than the OpenAI default of "developer".
      orig = Services.Globals.get_env(:fnord, :ai_provider)
      Services.Globals.put_env(:fnord, :ai_provider, "venice")
      on_exit(fn -> Services.Globals.put_env(:fnord, :ai_provider, orig) end)
      :ok
    end

    test "minimal payload contains model, default response_format, strip_thinking, and untouched messages" do
      model = Model.new("m", 1024)
      payload = Builder.build_payload(model, [], nil, nil, false, nil)
      assert payload[:model] == "m"
      assert payload[:messages] == []
      assert payload[:response_format] == %{type: "text"}
      # strip_thinking_response is always on for Venice - prevents <think>
      # block leakage that breaks downstream JSON parsing.
      assert payload[:venice_parameters] == %{strip_thinking_response: true}
      refute Map.has_key?(payload, :tools)
      refute Map.has_key?(payload, :reasoning_effort)
    end

    test "no response_format instruction is appended for the default text case" do
      # The instruction is only useful when the caller requested
      # structured output. Appending it for plain text invites Venice
      # models to echo the JSON literal back into the response body
      # (observed leaking into the MOTD output).
      model = Model.new("m", 1024)
      user_msg = %{role: "user", content: "hello"}
      payload = Builder.build_payload(model, [user_msg], nil, nil, false, nil)
      assert payload[:messages] == [user_msg]
    end

    test "json_schema instruction sends only the inner schema, not the OpenAI envelope" do
      # Dumping the full `{"type": "json_schema", "json_schema": {...}}`
      # envelope tempts smaller Venice models into echoing it back as
      # the response. The instruction unwraps to the actual schema and
      # explicitly tells the model not to echo it.
      model = Model.new("m", 1024)
      rf = %{type: "json_schema", json_schema: %{name: "review_estimate", schema: %{type: "object"}}}
      payload = Builder.build_payload(model, [], nil, rf, false, nil)
      [msg] = payload[:messages]
      assert msg.role == "system"
      # Schema content is present.
      assert msg.content =~ ~s("type": "object")
      # Schema name surfaces for model context.
      assert msg.content =~ "review_estimate"
      # Anti-echo guidance is in the instruction.
      assert msg.content =~ "Do not echo the schema"
      assert msg.content =~ "VALIDATES against the schema"
      # The OpenAI envelope keys are NOT in the instruction body.
      refute msg.content =~ ~s("type": "json_schema")
      refute msg.content =~ ~s("json_schema":)
    end

    test "json_object instruction is a short respond-with-JSON directive" do
      model = Model.new("m", 1024)
      user_msg = %{role: "user", content: "hello"}
      rf = %{type: "json_object"}
      payload = Builder.build_payload(model, [user_msg], nil, rf, false, nil)
      assert [^user_msg, instr] = payload[:messages]
      assert instr.role == "system"
      assert instr.content =~ "valid JSON"
      # No JSON schema dump for json_object.
      refute instr.content =~ "```json"
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

    test "venice_parameters carries strip_thinking_response even when web_search? is false" do
      # strip_thinking_response is unconditional - <think> blocks leaking
      # into structured-JSON agents (deduplicator, indexer) is the root
      # cause it addresses, independent of web search.
      m_cap = Model.new("m", 1024, :none, supports_web_search: true)
      vp = Builder.build_payload(m_cap, [], nil, nil, false, nil)[:venice_parameters]
      assert vp == %{strip_thinking_response: true}
    end

    test "raises when web_search? is true but the model lacks the capability" do
      m_no = Model.new("m", 1024, :none, supports_web_search: false)

      assert_raise ArgumentError, ~r/does not support web search/, fn ->
        Builder.build_payload(m_no, [], nil, nil, true, nil)
      end
    end
  end
end

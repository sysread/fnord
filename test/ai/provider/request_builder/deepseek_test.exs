defmodule AI.Provider.RequestBuilder.DeepSeekTest do
  @moduledoc """
  Behavioral tests for the DeepSeek request-builder. DeepSeek is
  OpenAI-API-compatible at the chat-completions surface.
  """

  use Fnord.TestCase, async: false
  alias AI.Model
  alias AI.Provider.RequestBuilder.DeepSeek, as: Builder

  describe "system_role/0" do
    test "returns \"system\" - DeepSeek follows the legacy role convention" do
      assert Builder.system_role() == "system"
    end
  end

  describe "api_key!/0" do
    setup do
      orig_fnord = System.get_env("FNORD_DEEPSEEK_API_KEY")
      orig_canonical = System.get_env("DEEPSEEK_API_KEY")

      System.delete_env("FNORD_DEEPSEEK_API_KEY")
      System.delete_env("DEEPSEEK_API_KEY")

      on_exit(fn ->
        if orig_fnord, do: System.put_env("FNORD_DEEPSEEK_API_KEY", orig_fnord)
        if orig_canonical, do: System.put_env("DEEPSEEK_API_KEY", orig_canonical)
      end)

      :ok
    end

    test "raises with both env-var names in the message when neither is set" do
      assert_raise RuntimeError, ~r/FNORD_DEEPSEEK_API_KEY or DEEPSEEK_API_KEY/, fn ->
        Builder.api_key!()
      end
    end

    test "fnord-prefixed name takes precedence" do
      System.put_env("FNORD_DEEPSEEK_API_KEY", "fk")
      System.put_env("DEEPSEEK_API_KEY", "ok")
      assert Builder.api_key!() == "fk"
    end

    test "falls back to upstream-canonical name when fnord-prefixed is unset" do
      System.put_env("DEEPSEEK_API_KEY", "ok")
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
    setup do
      # `AI.Util.system_msg/1` consults `AI.Provider.system_role/0` -> the
      # active provider's request builder. Pin the provider to "deepseek"
      # so injected developer messages get the role DeepSeek expects.
      orig = Services.Globals.get_env(:fnord, :ai_provider)
      Services.Globals.put_env(:fnord, :ai_provider, "deepseek")
      on_exit(fn -> Services.Globals.put_env(:fnord, :ai_provider, orig) end)
      :ok
    end

    test "minimal payload omits response_format entirely (DeepSeek defaults to text)" do
      model = Model.new("m", 1024)
      payload = Builder.build_payload(model, [], nil, nil, false, nil)
      assert payload[:model] == "m"
      assert payload[:messages] == []
      # DeepSeek's chat-completions API accepts only `text` and
      # `json_object`. When the caller passes nil we omit the field
      # entirely; DeepSeek's documented default is text.
      refute Map.has_key?(payload, :response_format)
      refute Map.has_key?(payload, :tools)
      refute Map.has_key?(payload, :reasoning_effort)
      refute Map.has_key?(payload, :verbosity)
      refute Map.has_key?(payload, :web_search_options)
    end

    test "tools field present when tools are passed" do
      model = Model.new("m", 1024)
      tools = [%{type: "function", function: %{name: "x"}}]
      payload = Builder.build_payload(model, [], tools, nil, false, nil)
      assert payload[:tools] == tools
    end

    test "json_schema response_format degrades to json_object on the wire" do
      # DeepSeek rejects json_schema with 400 ("This response_format
      # type is unavailable now"). The builder degrades to json_object
      # and injects the schema as a developer instruction so the
      # caller's contract still lands at the model.
      model = Model.new("m", 1024)
      rf = %{type: "json_schema", json_schema: %{name: "S", schema: %{type: "object"}}}
      payload = Builder.build_payload(model, [], nil, rf, false, nil)
      assert payload[:response_format] == %{type: "json_object"}
      # Developer message restating the schema was appended.
      [msg] = payload[:messages]
      assert msg.role == "system"
      # DeepSeek json_object mode requires the literal word "JSON" in
      # the prompt; the injected text must include it.
      assert msg.content =~ "JSON"
      assert msg.content =~ ~s("type": "object")
      assert msg.content =~ "Do not echo the schema"
      # Schema name surfaces too.
      assert msg.content =~ "S"
    end

    test "json_object response_format is preserved and gets a short JSON instruction" do
      model = Model.new("m", 1024)
      user_msg = %{role: "user", content: "hi"}
      rf = %{type: "json_object"}
      payload = Builder.build_payload(model, [user_msg], nil, rf, false, nil)
      assert payload[:response_format] == %{type: "json_object"}
      [^user_msg, instr] = payload[:messages]
      assert instr.role == "system"
      assert instr.content =~ "JSON"
      refute instr.content =~ "```json"
    end

    test "text response_format is preserved with no injected instruction" do
      model = Model.new("m", 1024)
      rf = %{type: "text"}
      payload = Builder.build_payload(model, [], nil, rf, false, nil)
      assert payload[:response_format] == rf
      assert payload[:messages] == []
    end

    test "verbosity is silently dropped (DeepSeek doesn't accept it)" do
      model = Model.new("m", 1024)
      payload = Builder.build_payload(model, [], nil, nil, false, "high")
      refute Map.has_key?(payload, :verbosity)
    end

    test "raises when web_search? is true (DeepSeek has no web-search-capable model)" do
      model = Model.new("m", 1024, :none, supports_web_search: false)

      assert_raise ArgumentError, ~r/no web-search-capable model/, fn ->
        Builder.build_payload(model, [], nil, nil, true, nil)
      end
    end

    test "reasoning_effort emitted only when capability flag is true" do
      m_on = Model.new("m", 1024, :high, supports_reasoning: true)
      m_off = Model.new("m", 1024, :high, supports_reasoning: false)

      assert Builder.build_payload(m_on, [], nil, nil, false, nil)[:reasoning_effort] == "high"

      refute Map.has_key?(
               Builder.build_payload(m_off, [], nil, nil, false, nil),
               :reasoning_effort
             )
    end

    test "low / medium / high reasoning levels map to their wire strings" do
      for level <- [:low, :medium, :high] do
        m = Model.new("m", 1024, level, supports_reasoning: true)

        assert Builder.build_payload(m, [], nil, nil, false, nil)[:reasoning_effort] ==
                 Atom.to_string(level)
      end
    end

    test "unmapped reasoning levels (e.g. :none, :minimal) drop the reasoning_effort field" do
      m_none = Model.new("m", 1024, :none, supports_reasoning: true)
      m_minimal = Model.new("m", 1024, :minimal, supports_reasoning: true)

      refute Map.has_key?(
               Builder.build_payload(m_none, [], nil, nil, false, nil),
               :reasoning_effort
             )

      refute Map.has_key?(
               Builder.build_payload(m_minimal, [], nil, nil, false, nil),
               :reasoning_effort
             )
    end
  end
end

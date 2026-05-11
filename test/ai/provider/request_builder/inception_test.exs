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
    test "returns \"system\" - Inception explicitly rejects \"developer\"" do
      # Inception's chat-completions API rejects `developer`-role
      # messages with a 500 (validation error: "Role must be one of
      # {'assistant', 'system', 'tool', 'user', 'function'}"). The
      # legacy `system` role is the only system-equivalent it accepts.
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
    test "minimal payload contains model, default response_format, max_tokens, and untouched messages" do
      model = Model.new("m", 1024)
      payload = Builder.build_payload(model, [], nil, nil, false, nil)
      assert payload[:model] == "m"
      assert payload[:messages] == []
      assert payload[:response_format] == %{type: "text"}
      # Inception's default max_tokens is 8192; we set it explicitly
      # higher to leave headroom for code-heavy responses.
      assert payload[:max_tokens] == 50_000
      # Inception does not accept verbosity or web_search_options - the
      # builder must NOT emit them. reasoning_effort is gated on the
      # model's supports_reasoning flag (default false for a bare
      # Model.new/2).
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

    test "reasoning_effort emitted only when capability flag is true" do
      m_on = Model.new("m", 1024, :high, supports_reasoning: true)
      m_off = Model.new("m", 1024, :high, supports_reasoning: false)

      assert Builder.build_payload(m_on, [], nil, nil, false, nil)[:reasoning_effort] == "high"

      refute Map.has_key?(
               Builder.build_payload(m_off, [], nil, nil, false, nil),
               :reasoning_effort
             )
    end

    test ":instant reasoning level maps to wire string \"instant\"" do
      # Inception-/mercury-2-specific level alongside the OpenAI-
      # standard low/medium/high. Pinned here so a future cleanup that
      # accidentally drops it shows up as a test failure rather than
      # silently sending no reasoning hint.
      m = Model.new("m", 1024, :instant, supports_reasoning: true)
      assert Builder.build_payload(m, [], nil, nil, false, nil)[:reasoning_effort] == "instant"
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

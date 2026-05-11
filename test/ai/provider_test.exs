defmodule AI.ProviderTest do
  @moduledoc """
  Tests for the provider resolution chain and module routing.

  Provider resolution priority is:
    1. Globals override (`Services.Globals.put_env(:fnord, :ai_provider, ...)`),
       which the CLI flag layer writes to
    2. `FNORD_AI_PROVIDER` environment variable
    3. `settings.json` top-level `"ai_provider"` key
    4. Default `"openai"`

  Tests below construct each layer in isolation and verify the resolved
  provider matches expectations. Unknown values must raise from `init/0`.
  """

  use Fnord.TestCase, async: false

  setup do
    # Each test starts from a clean slate: clear any in-process globals
    # carried over from previous tests, and clear the env var.
    Services.Globals.delete_env(:fnord, :ai_provider)
    Util.Env.put_env("FNORD_AI_PROVIDER", "")

    on_exit(fn ->
      Services.Globals.delete_env(:fnord, :ai_provider)
      Util.Env.put_env("FNORD_AI_PROVIDER", "")
    end)

    :ok
  end

  describe "current/0" do
    test "defaults to openai when nothing is configured" do
      assert AI.Provider.current() == "openai"
    end

    test "reads the runtime override from globals" do
      Services.Globals.put_env(:fnord, :ai_provider, "openai")
      assert AI.Provider.current() == "openai"
    end
  end

  describe "init/0" do
    test "default fallback resolves to openai" do
      :ok = AI.Provider.init()
      assert AI.Provider.current() == "openai"
    end

    test "env var is honored when no globals override" do
      Util.Env.put_env("FNORD_AI_PROVIDER", "openai")
      :ok = AI.Provider.init()
      assert AI.Provider.current() == "openai"
    end

    test "settings.json value is honored when no globals or env override" do
      mock_project("p1")
      settings = Settings.new()
      Settings.update(settings, "ai_provider", fn _ -> "openai" end)

      :ok = AI.Provider.init()
      assert AI.Provider.current() == "openai"
    end

    test "globals override beats env var" do
      Util.Env.put_env("FNORD_AI_PROVIDER", "definitely-not-real")
      Services.Globals.put_env(:fnord, :ai_provider, "openai")

      :ok = AI.Provider.init()
      assert AI.Provider.current() == "openai"
    end

    test "env var beats settings.json value" do
      mock_project("p2")
      settings = Settings.new()
      Settings.update(settings, "ai_provider", fn _ -> "definitely-not-real" end)
      Util.Env.put_env("FNORD_AI_PROVIDER", "openai")

      :ok = AI.Provider.init()
      assert AI.Provider.current() == "openai"
    end

    test "unknown provider raises with a descriptive message" do
      Util.Env.put_env("FNORD_AI_PROVIDER", "bogus")

      assert_raise RuntimeError, ~r/Unknown AI provider/, fn ->
        AI.Provider.init()
      end
    end

    test "empty string env var is treated as unset" do
      Util.Env.put_env("FNORD_AI_PROVIDER", "")
      :ok = AI.Provider.init()
      assert AI.Provider.current() == "openai"
    end
  end

  describe "module_for/1" do
    test "all kinds resolve to OpenAI modules when provider is openai" do
      Services.Globals.put_env(:fnord, :ai_provider, "openai")

      assert AI.Provider.module_for(:endpoint) == AI.Endpoint.OpenAI
      assert AI.Provider.module_for(:model) == AI.Model.OpenAI
      assert AI.Provider.module_for(:request_builder) == AI.Provider.RequestBuilder.OpenAI
      assert AI.Provider.module_for(:response_parser) == AI.Provider.ResponseParser.OpenAI
      assert AI.Provider.module_for(:web_search) == AI.Provider.WebSearch.OpenAI
      assert AI.Provider.module_for(:health) == AI.Provider.Health.OpenAI
    end

    test "all kinds resolve to Venice modules when provider is venice" do
      Services.Globals.put_env(:fnord, :ai_provider, "venice")

      assert AI.Provider.module_for(:endpoint) == AI.Endpoint.Venice
      assert AI.Provider.module_for(:model) == AI.Model.Venice
      assert AI.Provider.module_for(:request_builder) == AI.Provider.RequestBuilder.Venice
      assert AI.Provider.module_for(:response_parser) == AI.Provider.ResponseParser.Venice
      assert AI.Provider.module_for(:web_search) == AI.Provider.WebSearch.Venice
      assert AI.Provider.module_for(:health) == AI.Provider.Health.Venice
    end
  end

  describe "system_role/0" do
    test "openai resolves to \"developer\"" do
      Services.Globals.put_env(:fnord, :ai_provider, "openai")
      assert AI.Provider.system_role() == "developer"
    end

    test "venice resolves to \"system\"" do
      # Venice mirrors OpenAI's wire shape but follows the legacy
      # `system` role convention. Sending `developer`-role messages to
      # Venice causes them to be silently dropped/downgraded, which
      # erases any schema instructions or step prompts attached to
      # them - hence the per-provider role.
      Services.Globals.put_env(:fnord, :ai_provider, "venice")
      assert AI.Provider.system_role() == "system"
    end
  end

  describe "known_providers/0" do
    test "openai and venice are in the known set" do
      assert "openai" in AI.Provider.known_providers()
      assert "venice" in AI.Provider.known_providers()
    end
  end

  describe "venice provider end-to-end resolution" do
    test "venice flows through the env var path" do
      Util.Env.put_env("FNORD_AI_PROVIDER", "venice")
      :ok = AI.Provider.init()
      assert AI.Provider.current() == "venice"
    end
  end
end

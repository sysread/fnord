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
    test ":endpoint resolves to AI.Endpoint.OpenAI for openai" do
      Services.Globals.put_env(:fnord, :ai_provider, "openai")
      assert AI.Provider.module_for(:endpoint) == AI.Endpoint.OpenAI
    end

    test ":model resolves to AI.Model.OpenAI for openai" do
      Services.Globals.put_env(:fnord, :ai_provider, "openai")
      assert AI.Provider.module_for(:model) == AI.Model.OpenAI
    end
  end

  describe "known_providers/0" do
    test "openai is in the known set" do
      assert "openai" in AI.Provider.known_providers()
    end
  end
end

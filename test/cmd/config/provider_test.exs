defmodule Cmd.Config.ProviderTest do
  @moduledoc """
  Tests for the `fnord config provider` subcommand surface. These cover
  the dispatch logic and the persistence behavior; they do not exercise
  the network-bound health check (that lives in the per-provider
  health-module tests).
  """

  use Fnord.TestCase, async: false
  alias Cmd.Config.Provider

  setup do
    # Ensure each test starts with no provider override in globals so
    # we can verify the resolution chain freshly.
    Services.Globals.delete_env(:fnord, :ai_provider)
    Util.Env.put_env("FNORD_AI_PROVIDER", "")

    on_exit(fn ->
      Services.Globals.delete_env(:fnord, :ai_provider)
      Util.Env.put_env("FNORD_AI_PROVIDER", "")
    end)

    :ok
  end

  describe "list" do
    test "produces a JSON report including the active provider" do
      Services.Globals.put_env(:fnord, :ai_provider, "openai")
      output = capture_io(fn -> Provider.run(%{}, [:provider, :list], []) end)
      assert output =~ "\"active\": \"openai\""
      assert output =~ "\"known\""
      assert output =~ "openai"
      assert output =~ "venice"
    end
  end

  describe "set" do
    setup :mock_project_for_settings

    test "persists a known provider to settings.json and globals" do
      capture_io(fn -> Provider.run(%{}, [:provider, :set], ["venice"]) end)

      # Settings file gets the value.
      assert Settings.new() |> Settings.get("ai_provider") == "venice"
      # In-process globals follow.
      assert Services.Globals.get_env(:fnord, :ai_provider) == "venice"
    end

    test "rejects an unknown provider without writing" do
      # UI.error routes through Logger; we verify the side effect rather
      # than the log content, since that is what actually matters for
      # the user (no bogus value persisted).
      capture_io(fn ->
        Provider.run(%{}, [:provider, :set], ["definitely-not-real"])
      end)

      assert Settings.new() |> Settings.get("ai_provider") == nil
    end

    test "missing argument does not crash" do
      # Just exercise the path - the error goes through Logger, not
      # stdio. The contract is "do not raise"; we verify that.
      capture_io(fn ->
        Provider.run(%{}, [:provider, :set], [])
      end)
    end
  end

  describe "check" do
    test "unknown provider name does not crash" do
      capture_io(fn ->
        Provider.run(%{}, [:provider, :check], ["definitely-not-real"])
      end)
    end
  end

  # `set` writes through Settings.update, which wants a settings file in
  # place. mock_project/1 establishes the standard fnord-home test
  # tmpdir; the settings file gets created on first read by Settings.new.
  defp mock_project_for_settings(_ctx) do
    mock_project("provider-test-project")
    :ok
  end
end

defmodule AI.Provider do
  @moduledoc """
  Resolve the configured AI provider implementation modules.

  Providers are selected globally via the user's settings file (~/.fnord/settings.json)
  under the top-level key "ai_provider". Defaults to "openai" when missing.

  This module maps provider keys to concrete implementation modules for
  endpoint (HTTP endpoint path + error classifier) and model profiles.
  """

  @type provider_key :: binary()

  @spec current() :: provider_key
  def current() do
    # Prefer a runtime env override to avoid early Settings.new/0 during compile.
    case safe_get_env(:ai_provider) do
      {:ok, nil} ->
        settings = Settings.new()
        Settings.get(settings, "ai_provider", "openai")

      {:ok, key} ->
        key

      :no_globals ->
        "openai"
    end
  end

  defp read_provider_from_settings() do
    try do
      settings = Settings.new()
      Settings.get(settings, "ai_provider", "openai")
    rescue
      _ -> "openai"
    end
  end

  defp safe_get_env(key) do
    case :ets.whereis(:globals_roots) do
      :undefined -> :no_globals
      _tid -> {:ok, Services.Globals.get_env(:fnord, key, nil)}
    end
  end

  @spec module_for(:endpoint | :model) :: module
  def module_for(:endpoint) do
    case current() do
      "openai" -> AI.Endpoint.OpenAI
      other -> unknown_provider(:endpoint, other)
    end
  end

  def module_for(:model) do
    case current() do
      "openai" -> AI.Model.OpenAI
      other -> unknown_provider(:model, other)
    end
  end

  defp unknown_provider(kind, other) do
    UI.warn("[AI.Provider] Unknown provider '#{other}' for #{kind}, defaulting to OpenAI")

    case kind do
      :endpoint -> AI.Endpoint.OpenAI
      :model -> AI.Model.OpenAI
    end
  end
end

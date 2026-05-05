defmodule Cmd.Config.Provider do
  @moduledoc """
  CLI surface for inspecting and switching the active AI provider.

  Three subcommands:

    - `list` - show the current provider, the resolution layers (CLI /
      env / settings.json), and the env-var presence for each known
      provider's API key (masked).
    - `set <provider>` - persist the provider to `settings.json`'s
      top-level `"ai_provider"` key. With `--check`, run a health check
      after persisting so the user gets immediate feedback on whether
      the new provider's environment is in order.
    - `check [<provider>]` - on-demand health check. Defaults to the
      currently active provider.

  ## Why on-demand and not at startup

  Hitting the provider's `/v1/models` endpoint on every fnord invocation
  would add latency to every command for one user-facing failure mode
  (misconfigured key). The cheap startup check (validate the provider
  string is in `known_providers/0`) is enough to catch typos. Network
  validation is reserved for `fnord config provider check` so the user
  invokes it intentionally.
  """

  alias AI.Provider

  @doc "Dispatcher for `fnord config provider <subcommand>`."
  @spec run(map(), list(), list()) :: :ok
  def run(opts, command, args)

  def run(_opts, [:provider, :list], _args) do
    print_listing()
    :ok
  end

  def run(opts, [:provider, :set], args) do
    case fetch_provider_arg(opts, args) do
      {:ok, name} ->
        case set_provider(name, !!opts[:check]) do
          :ok -> :ok
          {:error, reason} -> UI.error(reason)
        end

      {:error, reason} ->
        UI.error(reason)
    end
  end

  def run(opts, [:provider, :check], args) do
    # Argument is optional - default to the active provider if the
    # caller did not name one explicitly.
    target =
      case fetch_provider_arg(opts, args) do
        {:ok, name} -> name
        {:error, _} -> Provider.current()
      end

    if target in Provider.known_providers() do
      run_health_check(target)
    else
      UI.error("Unknown provider '#{target}'. Known: #{inspect(Provider.known_providers())}")
    end
  end

  # ---------------------------------------------------------------------------
  # `list` implementation.
  #
  # Prints a structured report of the active provider plus, for each
  # known provider, whether its API key env vars are populated. Keeps
  # the actual key value out of the output (masking is unnecessary
  # because we never echo the value at all - we only report whether it
  # is set and via which env var).
  # ---------------------------------------------------------------------------
  defp print_listing() do
    %{
      "active" => Provider.current(),
      "known" => Provider.known_providers(),
      "settings_json" => settings_value(),
      "env_var" => Util.Env.get_env("FNORD_AI_PROVIDER", nil),
      "env_keys" => env_key_status()
    }
    |> SafeJson.encode!(pretty: true)
    |> UI.puts()
  end

  defp settings_value() do
    Settings.new() |> Settings.get("ai_provider", nil)
  rescue
    _ -> nil
  end

  # Report which env var (if any) supplies each provider's API key.
  # We do not echo the actual value - just which name resolved.
  defp env_key_status() do
    %{
      "openai" => env_key_for(["FNORD_OPENAI_API_KEY", "OPENAI_API_KEY"]),
      "venice" => env_key_for(["FNORD_VENICE_API_KEY", "VENICE_API_KEY"])
    }
  end

  defp env_key_for(candidates) do
    Enum.find(candidates, fn name ->
      case Util.Env.get_env(name, nil) do
        nil -> false
        "" -> false
        _ -> true
      end
    end) || "(unset)"
  end

  # ---------------------------------------------------------------------------
  # `set` implementation.
  #
  # Persists the provider key to settings.json, then optionally runs a
  # health check. Validation against `known_providers/0` happens before
  # the write; an unknown provider never reaches disk.
  # ---------------------------------------------------------------------------
  defp set_provider(name, run_check?) do
    if name in Provider.known_providers() do
      Settings.update(Settings.new(), "ai_provider", fn _ -> name end)
      Services.Globals.put_env(:fnord, :ai_provider, name)
      UI.puts("Set ai_provider = #{name}")

      if run_check? do
        run_health_check(name)
      else
        :ok
      end
    else
      {:error,
       "Unknown provider '#{name}'. Known providers: #{Enum.join(Provider.known_providers(), ", ")}"}
    end
  end

  # ---------------------------------------------------------------------------
  # `check` implementation.
  #
  # Temporarily flips the active provider to the requested target so
  # the per-provider health module is the right one, runs the check,
  # then restores the previous active provider. The flip is in-process
  # only; settings.json is not touched.
  # ---------------------------------------------------------------------------
  defp run_health_check(name) do
    previous = Services.Globals.get_env(:fnord, :ai_provider, nil)
    Services.Globals.put_env(:fnord, :ai_provider, name)

    try do
      health_mod = Provider.module_for(:health)
      UI.puts("Checking provider '#{name}'...")

      case apply(health_mod, :check, []) do
        {:ok, info} ->
          UI.puts("OK - #{format_info(info)}")
          :ok

        {:error, reason, message} ->
          UI.error("FAIL (#{reason}): #{message}")
          {:error, message}
      end
    after
      # Restore the previous active provider regardless of check
      # outcome. `set/2` callers expect the in-process state to reflect
      # whatever they just wrote.
      if is_nil(previous) do
        Services.Globals.delete_env(:fnord, :ai_provider)
      else
        Services.Globals.put_env(:fnord, :ai_provider, previous)
      end
    end
  end

  defp format_info(%{model_count: n}), do: "API key valid; #{n} models available."
  defp format_info(other), do: inspect(other)

  # ---------------------------------------------------------------------------
  # Shared helpers.
  # ---------------------------------------------------------------------------

  # Pull a `:provider` key out of either opts or args. The CLI spec
  # registers the value as a positional arg, but we accept opts for
  # programmatic callers (tests, internal dispatch).
  defp fetch_provider_arg(opts, args) do
    case Map.get(opts, :provider) do
      v when is_binary(v) and v != "" ->
        {:ok, v}

      _ ->
        case args do
          [name | _] when is_binary(name) and name != "" -> {:ok, name}
          _ -> {:error, "Provider name required"}
        end
    end
  end
end

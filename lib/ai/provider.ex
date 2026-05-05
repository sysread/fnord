defmodule AI.Provider do
  @moduledoc """
  Resolve the configured AI provider implementation modules.

  The provider is the central pivot for swapping between OpenAI, Venice, and
  any future LLM backend. A single string value (`"openai"`, `"venice"`, ...)
  selects a stack of concrete modules:

  - `:endpoint` - the HTTP endpoint URL and provider-specific error
    classifier consumed by `AI.Endpoint`'s retry harness
  - `:model` - the catalog of named profiles (smart/balanced/fast/...)
    returned by `AI.Model` factory functions

  Future stages of the Venice port will register two more behaviours under
  `module_for/1`:

  - `:request_builder` - turns abstract request args into a provider-
    specific HTTP payload + headers
  - `:response_parser` - turns raw HTTP success/error bodies into the
    completion-level `{:ok, :msg, ...}` / `{:ok, :tool, ...}` family
  - `:web_search` - performs a web search according to the provider's
    native mechanism (sub-completion on OpenAI; inline `venice_parameters`
    on Venice)

  ## Resolution priority

  The active provider is resolved with this priority, highest first:

  1. The runtime override at `Services.Globals.get_env(:fnord,
     :ai_provider, ...)`. CLI handlers and `init/0` write here.
  2. The environment variable `FNORD_AI_PROVIDER`.
  3. `settings.json` top-level key `"ai_provider"`.
  4. The default, `"openai"`.

  `init/0` runs once at startup (from `Fnord.set_globals/1`), reads the
  effective value, validates it against `known_providers/0`, and writes
  the resolved value into globals so subsequent calls to `current/0` are
  cheap and side-effect-free.

  An unknown provider value is treated as a hard error: `init/0` raises
  immediately with a clear message rather than silently falling back to
  OpenAI. Silently mapping an unrecognized provider string to the default
  would hide configuration bugs that are far easier to diagnose at startup.
  """

  @type provider_key :: binary()

  @default_provider "openai"

  @env_var "FNORD_AI_PROVIDER"

  @doc """
  The set of provider keys this build understands. Stage 0 ships with
  OpenAI only; Stage 3 adds `"venice"`.
  """
  @spec known_providers() :: [provider_key]
  def known_providers, do: ["openai"]

  @doc """
  Resolve and persist the active provider for this invocation.

  Called once from `Fnord.set_globals/1` after CLI parsing. Reads the
  resolution chain (CLI override already in globals > env > settings >
  default), validates the result, and writes it back into globals.

  Raises if the resolved provider is not in `known_providers/0`.
  """
  @spec init() :: :ok | no_return
  def init() do
    resolved = resolve()

    unless resolved in known_providers() do
      raise """
      Unknown AI provider: #{inspect(resolved)}.

      Configured via one of:
        - --provider CLI flag (highest priority)
        - #{@env_var} environment variable
        - settings.json top-level "ai_provider" key

      Known providers: #{Enum.join(known_providers(), ", ")}
      """
    end

    Services.Globals.put_env(:fnord, :ai_provider, resolved)
    :ok
  end

  @doc """
  Return the active provider key.

  Reads from globals when available; falls back to the default when called
  before `init/0` has run (e.g. during compile-time module loading or in
  unit tests that bypass `Services.start_all/0`).
  """
  @spec current() :: provider_key
  def current() do
    case safe_get_env(:ai_provider) do
      {:ok, nil} -> @default_provider
      {:ok, key} -> key
      :no_globals -> @default_provider
    end
  end

  @doc """
  Map a behaviour kind to the concrete implementation module for the
  active provider. Used by callers (request layer, completion layer, model
  catalog) that should not name a provider directly.

  Unknown kinds raise; an unknown provider on a known kind warns and
  falls back to the OpenAI implementation. The asymmetry is intentional:
  unknown kinds are programmer errors and should fail loud, while unknown
  providers are configuration errors that `init/0` already caught - the
  warn-and-fallback here is a defense-in-depth backstop.
  """
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

  # ---------------------------------------------------------------------------
  # Internal: resolution chain.
  #
  # CLI override has already been written to globals by `Fnord.set_globals/1`
  # before `init/0` runs, so step 1 of the priority chain is just a globals
  # read. The env-var and settings lookups are performed only when globals
  # is empty.
  # ---------------------------------------------------------------------------
  @spec resolve() :: provider_key
  defp resolve() do
    cond do
      cli = cli_override() -> cli
      env = env_override() -> env
      stg = settings_override() -> stg
      true -> @default_provider
    end
  end

  defp cli_override() do
    case safe_get_env(:ai_provider) do
      {:ok, value} when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp env_override() do
    case Util.Env.get_env(@env_var, nil) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp settings_override() do
    try do
      Settings.new()
      |> Settings.get("ai_provider", nil)
      |> case do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    rescue
      # Settings.new/0 can raise if the file is corrupt or unreadable. Don't
      # let provider resolution take down startup over a settings issue;
      # other code paths will surface the same error with better context.
      _ -> nil
    end
  end

  defp safe_get_env(key) do
    case :ets.whereis(:globals_roots) do
      :undefined -> :no_globals
      _tid -> {:ok, Services.Globals.get_env(:fnord, key, nil)}
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

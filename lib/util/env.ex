defmodule Util.Env do
  @moduledoc """
  Utilities for interpreting environment variables used in fnord.

  Provide canonical parsing helpers so different runtime contexts treat
  environment values consistently (escript, mix run, CI, etc.).

  Reads consult a `Services.Globals`-scoped override before the real
  environment, so a process tree can see a different value than the VM at
  large (see `put_override/2`). In-VM env reads should always route through
  this module rather than `System.get_env` so they honor that scoping.
  """

  # Overrides live under {:env_override, var} in the :fnord Globals scope.
  # :unset is the "pretend the variable is not set" sentinel: a nil override
  # value cannot express that, because Globals returns the caller's default
  # for a missing key and nil for an explicit nil alike.
  @typep override :: binary | :unset | :no_override

  @doc """
  Return true when the provided environment value is considered truthy.

  Recognizes the common truthy values (case-insensitive): "1", "true", and "yes".
  Returns false for nil, empty strings, and other values.
  """
  @spec looks_truthy?(binary) :: boolean
  def looks_truthy?(env_var_name) do
    case fetch_env(env_var_name) do
      {:ok, v} ->
        truthy_value?(v)

      {:error, :not_set} ->
        false
    end
  end

  # Internal helper: interpret a raw env value (string) as truthy/falsey
  @spec truthy_value?(binary) :: boolean
  defp truthy_value?(val) do
    val
    |> String.trim()
    |> String.downcase()
    |> case do
      "1" -> true
      "true" -> true
      "yes" -> true
      _ -> false
    end
  end

  @spec mcp_debug_enabled?() :: boolean
  def mcp_debug_enabled? do
    looks_truthy?("FNORD_DEBUG_MCP")
  end

  @spec cursor_rules_debug_enabled?() :: boolean
  def cursor_rules_debug_enabled? do
    looks_truthy?("FNORD_DEBUG_CURSOR_RULES")
  end

  @spec get_env(binary, any) :: any
  def get_env(var, default \\ nil) do
    case fetch_env(var) do
      {:ok, v} -> v
      {:error, :not_set} -> default
    end
  end

  @spec fetch_env(binary) :: {:ok, binary} | {:error, :not_set}
  def fetch_env(var) do
    case get_override(var) do
      :no_override ->
        case System.get_env(var) do
          nil -> {:error, :not_set}
          v -> {:ok, v}
        end

      :unset ->
        {:error, :not_set}

      v when is_binary(v) ->
        {:ok, v}
    end
  end

  @doc """
  Override `var` for the current `Services.Globals` scope (process tree).
  Reads through this module see the override; the real environment - and
  therefore subprocesses - do not. `nil` makes the variable appear unset.

  This is the async-safe alternative to `put_env/2` for tests: System env is
  VM-global, so a per-test put/delete races every concurrently running test,
  while an override dies with the test's process tree.
  """
  @spec put_override(binary, binary | nil) :: :ok
  def put_override(var, nil) do
    Services.Globals.put_env(:fnord, {:env_override, var}, :unset)
  end

  def put_override(var, value) when is_binary(value) do
    Services.Globals.put_env(:fnord, {:env_override, var}, value)
  end

  @spec get_override(binary) :: override
  defp get_override(var) do
    # get_override, not get_env: env-override keys have no Application-env
    # counterpart, and get_env's no-root fallback would pass the tuple key to
    # Application.get_env - a runtime deprecation warning on Elixir >= 1.20
    # that lands in whatever test capture happens to be active.
    Services.Globals.get_override(:fnord, {:env_override, var}, :no_override)
  end

  @doc """
  Set the environment variable to the given value.
  """
  @spec put_env(binary, binary) :: :ok
  def put_env(var, value) do
    System.put_env(var, value)
  end

  @doc """
  Delete the environment variable.
  """
  @spec delete_env(binary) :: :ok
  def delete_env(var) do
    System.delete_env(var)
  end
end

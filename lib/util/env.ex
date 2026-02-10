defmodule Util.Env do
  @moduledoc """
  Utilities for interpreting environment variables used in fnord.

  Provide canonical parsing helpers so different runtime contexts treat
  environment values consistently (escript, mix run, CI, etc.).
  """

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

  @spec get_env(binary, any) :: any
  def get_env(var, default \\ nil) do
    case System.get_env(var) do
      nil -> default
      v -> v
    end
  end

  @spec fetch_env(binary) :: {:ok, binary} | {:error, :not_set}
  def fetch_env(var) do
    case System.get_env(var) do
      nil -> {:error, :not_set}
      v -> {:ok, v}
    end
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

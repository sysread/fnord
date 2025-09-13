defmodule HttpPool do
  @moduledoc """
  Provides a per-process HTTP pool override mechanism for Hackney pools.

  By default, calls to HTTP clients will use the `:ai_api` pool. Processes such
  as background indexers can override this setting locally, ensuring their
  HTTP requests are routed through a dedicated `:ai_indexer` pool without
  affecting other processes.
  """

  @default_pool :ai_api
  @key :http_pool_override

  @doc """
  Returns the current process HTTP pool override, defaulting to `:ai_api`.
  """
  @spec get() :: atom()
  def get do
    Process.get(@key, @default_pool)
  end

  @doc """
  Overrides the HTTP pool for the current process.

  ## Examples

      HttpPool.set(:ai_indexer)
  """
  @spec set(atom()) :: :ok
  def set(pool) when is_atom(pool) do
    Process.put(@key, pool)
    :ok
  end

  @doc """
  Clears any HTTP pool override in the current process, reverting to default.
  """
  @spec clear() :: :ok
  def clear do
    Process.delete(@key)
    :ok
  end

  @doc """
  Temporarily sets the HTTP pool override for the duration of the given function.

  The pool override is restored to its previous value after the function returns or raises.
  """
  @spec with_pool(atom(), (-> any())) :: any()
  def with_pool(pool, fun) when is_atom(pool) and is_function(fun, 0) do
    previous = Process.get(@key)
    Process.put(@key, pool)

    try do
      fun.()
    after
      restore(previous)
    end
  end

  defp restore(nil), do: Process.delete(@key)
  defp restore(previous), do: Process.put(@key, previous)
end

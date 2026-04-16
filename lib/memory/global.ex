defmodule Memory.Global do
  @moduledoc """
  Global memory storage implementation for the `Memory` behaviour.

  This module uses the shared file-backed `Memory.FileStore` and primarily
  supplies the global-memory runtime paths and availability semantics.
  Global memories are stored as JSON files in `~/.fnord/memory`.
  """

  # ----------------------------------------------------------------------------
  # Behaviour Implementation
  # ----------------------------------------------------------------------------
  @behaviour Memory

  @impl Memory
  def init(), do: Memory.FileStore.init(store())

  @impl Memory
  def list(), do: Memory.FileStore.list(store())

  @impl Memory
  def exists?(title), do: Memory.FileStore.exists?(store(), title)

  @impl Memory
  def read(title), do: Memory.FileStore.read(store(), title)

  @impl Memory
  def save(memory), do: Memory.FileStore.save(store(), memory)

  @impl Memory
  def forget(title), do: Memory.FileStore.forget(store(), title)

  @impl Memory
  def is_available?(), do: true

  @doc """
  Returns decoded global memories for integration points that need a one-pass
  listing path.

  Unlike `list/0`, which is the title-oriented listing required by the `Memory`
  behaviour, this function returns fully decoded `Memory` structs.
  """
  @spec list_memories() :: {:ok, [Memory.t()]} | {:error, term()}
  def list_memories(), do: Memory.FileStore.list_memories(store())

  @doc """
  Returns the global memory storage directory. Exposed so callers can
  build per-memory lock paths without importing the internal `store/0`
  helper.
  """
  @spec storage_path() :: String.t()
  def storage_path, do: Path.join(Store.store_home(), "memory")

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------
  defp store() do
    Memory.FileStore.new(
      storage_path: Path.join(Store.store_home(), "memory"),
      old_storage_path: Path.join(Store.store_home(), "memories"),
      debug_label: "memory:global"
    )
  end
end

defmodule Store.Project.Entry.StorageBehaviour do
  @moduledoc """
  Behaviour definition for persisting project entries in the store.

  Implementations of this behaviour manage the physical storage and retrieval
  of entries, abstracting over the underlying persistence mechanism.
  """
  alias Store.Project.Entry

  @callback exists?(Entry.t()) :: boolean()
  @callback create(Entry.t()) :: :ok
  @callback delete(Entry.t()) :: {:ok, [binary()]} | no_return()
  @callback is_incomplete?(Entry.t()) :: boolean()
  @callback is_stale?(Entry.t()) :: boolean()
  @callback read(Entry.t()) :: {:ok, map()} | {:error, any()}
  @callback save(Entry.t(), String.t(), String.t(), [float()]) :: :ok | {:error, any()}
end

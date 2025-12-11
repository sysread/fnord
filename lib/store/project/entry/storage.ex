defmodule Store.Project.Entry.Storage do
  @moduledoc """
  Façade over entry persistence using direct File operations and Entry submodules.
  """

  @behaviour Store.Project.Entry.StorageBehaviour

  alias Store.Project.Entry

  @impl true
  def exists?(entry), do: Entry.exists_in_store?(entry)

  @impl true
  def create(entry), do: Entry.create(entry)

  @impl true
  def delete(entry), do: {:ok, Entry.delete(entry)}

  @impl true
  def is_incomplete?(entry), do: Entry.is_incomplete?(entry)

  @impl true
  def is_stale?(entry), do: Entry.is_stale?(entry)

  @impl true
  def read(entry), do: Entry.read(entry)

  @impl true
  def save(entry, summary, outline, embeddings),
    do: Entry.save(entry, summary, outline, embeddings)
end

defmodule Patches do
  use GenServer

  # ----------------------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------------------

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  # Create and register a new temp file for a patch, returns {patch_id, path}
  def new_patch(contents) do
    GenServer.call(__MODULE__, {:new_patch, contents})
  end

  def get_patch(patch_id) do
    GenServer.call(__MODULE__, {:get, patch_id})
  end

  def delete_patch(patch_id) do
    GenServer.call(__MODULE__, {:delete, patch_id})
  end

  # ----------------------------------------------------------------------------
  # GenServer Callbacks
  # ----------------------------------------------------------------------------

  def init(state) do
    {:ok, state}
  end

  def handle_call({:new_patch, contents}, _from, state) do
    {:ok, path} = Briefly.create()
    :ok = File.write(path, contents)
    patch_id = :erlang.unique_integer([:positive, :monotonic])
    {:reply, {patch_id, path}, Map.put(state, patch_id, path)}
  end

  def handle_call({:get, patch_id}, _from, state) do
    case Map.fetch(state, patch_id) do
      {:ok, path} -> {:reply, {:ok, path}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:delete, patch_id}, _from, state) do
    new_state = Map.delete(state, patch_id)
    {:reply, :ok, new_state}
  end
end

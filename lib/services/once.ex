defmodule Services.Once do
  @moduledoc """
  This module provides a mechanism to perform actions only once, using a unique
  key provided by the caller to determine whether the action has already been
  performed this session.
  """

  use Agent

  @doc """
  Starts the agent that keeps track of seen keys.
  """
  def start_link() do
    Agent.start_link(fn -> Map.new() end, name: __MODULE__)
  end

  @doc """
  Checks if a key has been seen before. If the key has not been seen, it
  returns `{:error, :not_seen}`. If the key has been seen, it returns `{:ok,
  value}` where `value` is the value associated with the key, or `true` if no
  value was specified.
  """
  def get(key) do
    Agent.get(__MODULE__, fn seen ->
      with {:ok, value} <- Map.fetch(seen, key) do
        {:ok, value}
      else
        _ -> {:error, :not_seen}
      end
    end)
  end

  @doc """
  Marks a key as seen. If the key has not been seen before, it returns `true`
  and updates the internal state. If the key has already been seen, it returns
  `false` without updating the state.
  """
  def set(key, value \\ true) do
    Agent.get_and_update(__MODULE__, fn seen ->
      if Map.has_key?(seen, key) do
        {false, seen}
      else
        {true, Map.put(seen, key, value)}
      end
    end)
  end

  @doc """
  Emits a warning (using `UI.warn/1`) if the message has not yet been emitted
  during this session.
  """
  def warn(msg) do
    if set(msg) do
      UI.warn(msg)
    end

    :ok
  end
end

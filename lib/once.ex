defmodule Once do
  @moduledoc """
  This module provides a mechanism to perform actions only once, using a unique
  key provided by the caller to determine whether the action has already been
  performed this session.
  """

  use Agent

  @doc """
  Starts the agent that keeps track of seen keys.
  """
  def start_link(_opts) do
    Agent.start_link(fn -> Map.new() end, name: __MODULE__)
  end

  @doc """
  Marks a key as seen. If the key has not been seen before, it returns `true`
  and updates the internal state. If the key has already been seen, it returns
  `false` without updating the state.
  """
  def mark(key, value \\ true) do
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
    if mark(msg) do
      UI.warn(msg)
    end

    :ok
  end
end

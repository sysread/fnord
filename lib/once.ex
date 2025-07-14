defmodule Once do
  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> MapSet.new() end, name: __MODULE__)

  def warn(msg) do
    Agent.get_and_update(__MODULE__, fn seen ->
      if MapSet.member?(seen, msg) do
        {:ok, seen}
      else
        UI.warn(msg)
        {:ok, MapSet.put(seen, msg)}
      end
    end)
  end
end

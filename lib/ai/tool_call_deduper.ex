defmodule AI.ToolCallDeduper do
  @moduledoc false

  @spec key(map()) :: {String.t(), String.t()} | any()
  # Generates a deduplication key from the tool call's function and arguments.
  # Normalizes JSON arguments by decoding and re-encoding to ensure deterministic key ordering.
  def key(%{function: %{name: func, arguments: args_json}}) when is_binary(args_json) do
    case Jason.decode(args_json) do
      {:ok, decoded} -> {func, Jason.encode!(decoded)}
      _ -> {func, args_json}
    end
  end

  # Fallback for calls without binary arguments; yields nil to skip deduplication.
  def key(_call), do: nil

  @spec dedupe([map()]) :: [map()]
  # Filters the list of tool calls, collapsing duplicates based on dedupe key.
  # Retains the first occurrence of each unique key, preserving input order.
  def dedupe(tool_calls) when is_list(tool_calls) do
    {_seen, unique} =
      Enum.reduce(tool_calls, {MapSet.new(), []}, fn call, {seen, acc} ->
        key = key(call)

        if MapSet.member?(seen, key) do
          {seen, acc}
        else
          {MapSet.put(seen, key), acc ++ [call]}
        end
      end)

    unique
  end
end

defmodule Services.Task.Util do
  @moduledoc """
  Utility functions for task management.
  """

  @doc """
  Converts a task outcome from string or atom format to the canonical atom format.
  Returns :todo for any unrecognized values.
  """
  @spec normalize_outcome(binary | atom | any) :: :todo | :done | :failed
  def normalize_outcome(outcome) when is_binary(outcome) do
    case outcome do
      "todo" -> :todo
      "done" -> :done
      "failed" -> :failed
      _ -> :todo
    end
  end

  def normalize_outcome(outcome) when is_atom(outcome) and outcome in [:todo, :done, :failed] do
    outcome
  end

  def normalize_outcome(_), do: :todo
end

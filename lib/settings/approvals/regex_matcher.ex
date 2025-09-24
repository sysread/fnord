defmodule Settings.Approvals.RegexMatcher do
  @moduledoc """
  Provides functions to compile and match regular expression patterns for approvals.
  """

  @doc """
  Tests whether a single pattern string matches the given subject.

  Returns false if either argument is not a binary.
  """
  @spec matches?(String.t(), String.t()) :: boolean
  def matches?(pattern, subject) when is_binary(pattern) and is_binary(subject) do
    Regex.match?(Regex.compile!(pattern, "u"), subject)
  end

  def matches?(_, _), do: false
end

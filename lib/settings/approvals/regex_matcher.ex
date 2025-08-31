defmodule Settings.Approvals.RegexMatcher do
  @moduledoc """
  Provides functions to compile and match regular expression patterns for approvals.
  """

  @doc """
  Compiles a list of pattern strings into regex structs.

  Returns an empty list if the input is not a list.
  """
  @spec compile_patterns([String.t()]) :: [Regex.t()]
  def compile_patterns(patterns) when is_list(patterns) do
    Enum.map(patterns, &Regex.compile!(&1, "u"))
  end

  def compile_patterns(_), do: []

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

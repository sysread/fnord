defmodule AI.Model.OpenAI do
  @moduledoc """
  OpenAI model profiles and presets.

  Provides factory functions for common presets and encodes model name,
  context window, and reasoning level. Intended to be called indirectly via
  AI.Model wrapper functions.
  """

  @type t :: %AI.Model{
          model: binary,
          context: non_neg_integer,
          reasoning: atom,
          verbosity: atom | nil
        }

  @spec smart() :: AI.Model.t()
  def smart(), do: gpt5(:low)

  @spec smarter() :: AI.Model.t()
  def smarter(), do: gpt54(:low)

  @spec balanced() :: AI.Model.t()
  def balanced(), do: gpt5_mini()

  @spec fast() :: AI.Model.t()
  def fast(), do: gpt5_nano()

  @spec web_search() :: AI.Model.t()
  def web_search(), do: gpt_4o_mini_search_preview()

  @spec large_context(:smart | :balanced | :fast) :: AI.Model.t()
  def large_context(:smart), do: gpt41()
  def large_context(:balanced), do: gpt41_mini()
  def large_context(:fast), do: gpt41_nano()

  @spec gpt54(atom) :: AI.Model.t()
  def gpt54(reasoning \\ :medium), do: AI.Model.new("gpt-5.4", 1_050_000, reasoning)

  @spec gpt5(atom) :: AI.Model.t()
  def gpt5(reasoning \\ :medium), do: AI.Model.new("gpt-5-2025-08-07", 400_000, reasoning)

  @spec gpt5_mini() :: AI.Model.t()
  def gpt5_mini(), do: AI.Model.new("gpt-5.4-mini", 400_000, :none)

  @spec gpt5_nano() :: AI.Model.t()
  def gpt5_nano(), do: AI.Model.new("gpt-5.4-nano", 400_000, :none)

  @spec gpt41() :: AI.Model.t()
  def gpt41(), do: AI.Model.new("gpt-4.1", 1_000_000, :none)

  @spec gpt41_mini() :: AI.Model.t()
  def gpt41_mini(), do: AI.Model.new("gpt-4.1-mini", 1_000_000, :none)

  @spec gpt41_nano() :: AI.Model.t()
  def gpt41_nano(), do: AI.Model.new("gpt-4.1-nano", 1_000_000, :none)

  @spec gpt_4o_mini_search_preview() :: AI.Model.t()
  def gpt_4o_mini_search_preview(), do: AI.Model.new("gpt-4o-mini-search-preview", 128_000, :none)
end

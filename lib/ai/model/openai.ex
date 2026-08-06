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

  # ----------------------------------------------------------------------------
  # Common presets
  # ----------------------------------------------------------------------------
  @spec smarter() :: AI.Model.t()
  def smarter(), do: gpt56_terra(:medium)

  @spec smart() :: AI.Model.t()
  def smart(), do: gpt56_terra(:low)

  @spec balanced() :: AI.Model.t()
  def balanced(), do: gpt56_luna(:high)

  @spec fast() :: AI.Model.t()
  def fast(), do: gpt56_luna(:low)

  # The Responses API exposes web search as a tool entry
  # (%{type: "web_search"} in the tools array), not as a model variant. The
  # legacy gpt-5-search-api SKU only worked under chat completions and is
  # scheduled for removal. web_search/0 returns a normal model; callers that
  # need search must also pass web_search?: true to AI.Completion.get/1 so
  # the tool gets attached.
  @spec web_search() :: AI.Model.t()
  def web_search(), do: gpt56_luna(:low)

  @spec large_context(:smart | :balanced | :fast) :: AI.Model.t()
  def large_context(:smart), do: gpt56_luna(:high)
  def large_context(:balanced), do: gpt56_luna(:medium)
  def large_context(:fast), do: gpt56_luna(:low)

  # ----------------------------------------------------------------------------
  # API-specific model definitions
  # ----------------------------------------------------------------------------
  @spec gpt56_terra(atom) :: AI.Model.t()
  def gpt56_terra(reasoning \\ :medium), do: AI.Model.new("gpt-5.6-terra", 1_050_000, reasoning)

  @spec gpt56_luna(atom) :: AI.Model.t()
  def gpt56_luna(reasoning \\ :medium), do: AI.Model.new("gpt-5.6-luna", 1_050_000, reasoning)
end

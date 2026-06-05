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
  def smarter(), do: gpt55(:medium)

  @spec smart() :: AI.Model.t()
  def smart(), do: gpt54_mini(:medium)

  @spec balanced() :: AI.Model.t()
  def balanced(), do: gpt54_mini(:low)

  @spec fast() :: AI.Model.t()
  def fast(), do: gpt54_mini(:none)

  @spec web_search() :: AI.Model.t()
  def web_search(), do: gpt54(:none)

  @spec large_context(:smart | :balanced | :fast) :: AI.Model.t()
  def large_context(:smart), do: gpt41()
  def large_context(:balanced), do: gpt41_mini()
  def large_context(:fast), do: gpt41_nano()

  # ----------------------------------------------------------------------------
  # API-specific model definitions
  # ----------------------------------------------------------------------------
  @spec gpt55(atom) :: AI.Model.t()
  def gpt55(reasoning \\ :medium), do: AI.Model.new("gpt-5.5", 1_050_000, reasoning)

  @spec gpt54(atom) :: AI.Model.t()
  def gpt54(_), do: AI.Model.new("gpt-5.4", 1_050_000, :none)

  @spec gpt54_mini(atom) :: AI.Model.t()
  def gpt54_mini(_), do: AI.Model.new("gpt-5.4-mini", 400_000, :none)

  @spec gpt54_nano(atom) :: AI.Model.t()
  def gpt54_nano(_), do: AI.Model.new("gpt-5.4-nano", 400_000, :none)

  @spec gpt41() :: AI.Model.t()
  def gpt41(), do: AI.Model.new("gpt-4.1", 1_000_000, :none)

  @spec gpt41_mini() :: AI.Model.t()
  def gpt41_mini(), do: AI.Model.new("gpt-4.1-mini", 1_000_000, :none)

  @spec gpt41_nano() :: AI.Model.t()
  def gpt41_nano(), do: AI.Model.new("gpt-4.1-nano", 1_000_000, :none)

  # The Responses API exposes web search as a tool entry
  # (%{type: "web_search_preview"} in the tools array), not as a model variant.
  # web_search/0 returns a normal model; callers that need search must also pass
  # web_search?: true to AI.Completion.get/1 so the tool gets attached.
  @spec gpt5_web() :: AI.Model.t()
  def gpt5_web(), do: gpt54(:none)
end

defmodule AI.Model.DeepSeek do
  @moduledoc """
  DeepSeek model catalog.

  Single model in fnord's catalog: `deepseek-v4-flash`, 1M context,
  reasoning-capable, no provider-native web search. Every named
  profile factory routes through it with a per-role reasoning level;
  the role distinction is expressed entirely via the reasoning dial.

  If DeepSeek adds more models or a web-search capability, mirror the
  Venice catalog's per-capability factory pattern.
  """

  @behaviour AI.Model.Provider

  @type t :: %AI.Model{
          model: binary,
          context: non_neg_integer,
          reasoning: atom,
          verbosity: atom | nil,
          max_tokens: pos_integer | nil,
          supports_reasoning: boolean,
          supports_web_search: boolean
        }

  @impl AI.Model.Provider
  def smarter(), do: deepseek_v4_flash(:high)

  @impl AI.Model.Provider
  def smart(), do: deepseek_v4_flash(:medium)

  @impl AI.Model.Provider
  def balanced(), do: deepseek_v4_flash(:low)

  @impl AI.Model.Provider
  def fast(), do: deepseek_v4_flash(:none)

  @impl AI.Model.Provider
  def web_search(), do: deepseek_v4_flash(:none)

  @impl AI.Model.Provider
  def coding(), do: deepseek_v4_flash(:low)

  @impl AI.Model.Provider
  def large_context(:smart), do: deepseek_v4_flash(:high)
  def large_context(:balanced), do: deepseek_v4_flash(:medium)
  def large_context(:fast), do: deepseek_v4_flash(:none)

  # deepseek-v4-flash: 1M context, reasoning-capable. No provider-native
  # web search - the WebSearch.DeepSeek behaviour returns an unsupported
  # error so callers can route web search to a different provider.
  #
  # `max_tokens` is optional; nil leaves DeepSeek's default in play
  # (8192 at time of writing). Pass an integer to set a per-profile
  # response cap.
  def deepseek_v4_flash(reasoning \\ :medium, max_tokens \\ nil) do
    AI.Model.new("deepseek-v4-flash", 1_000_000, reasoning,
      supports_reasoning: true,
      supports_web_search: false,
      max_tokens: max_tokens
    )
  end
end

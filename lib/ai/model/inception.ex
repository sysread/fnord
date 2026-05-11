defmodule AI.Model.Inception do
  @moduledoc """
  Inception Labs model catalog.

  Inception ships a single hosted model, `mercury-2` (128K context).
  All named profile factories route through it; the reasoning level
  is `:none` because the model is not documented as reasoning-capable
  (no `reasoning_effort` field on the request) and web search is not
  supported by the provider.

  When Inception ships additional models or capabilities, add per-
  capability factories the way the Venice catalog does
  (`venice_default`, `venice_coding`, etc.). For now the single-model
  shape means every profile is the same model with different roles -
  the role distinction is purely orchestration-side.
  """

  @behaviour AI.Model.Provider

  @type t :: %AI.Model{
          model: binary,
          context: non_neg_integer,
          reasoning: atom,
          verbosity: atom | nil,
          supports_reasoning: boolean,
          supports_web_search: boolean
        }

  @impl AI.Model.Provider
  def smarter(), do: mercury_2()

  @impl AI.Model.Provider
  def smart(), do: mercury_2()

  @impl AI.Model.Provider
  def balanced(), do: mercury_2()

  @impl AI.Model.Provider
  def fast(), do: mercury_2()

  @impl AI.Model.Provider
  def web_search(), do: mercury_2()

  @impl AI.Model.Provider
  def coding(), do: mercury_2()

  @impl AI.Model.Provider
  def large_context(_tier), do: mercury_2()

  # Single model: mercury-2 at 128K context. supports_reasoning is
  # false because Inception does not document a reasoning_effort field;
  # supports_web_search is false because there is no provider-native
  # web search and we do not have a sub-completion search shim for
  # Inception (callers should route to a different provider for web
  # search).
  def mercury_2() do
    AI.Model.new("mercury-2", 128_000, :none,
      supports_reasoning: false,
      supports_web_search: false
    )
  end
end

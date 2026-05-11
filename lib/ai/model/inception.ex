defmodule AI.Model.Inception do
  @moduledoc """
  Inception Labs model catalog.

  Inception ships a single hosted model, `mercury-2` (128K context).
  All named profile factories route through it; the role distinction
  is expressed entirely through the per-profile reasoning level.

  `mercury_2/1` carries `supports_reasoning: true` so the request
  builder emits the configured `reasoning_effort` on the wire; web
  search is not supported by the provider, so `supports_web_search`
  is false and any caller asking for `web_search?: true` against
  Inception raises at the request-builder boundary.

  When Inception ships additional models, add per-capability factories
  the way the Venice catalog does (`venice_default`, `venice_coding`,
  etc.).
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
  def smarter(), do: mercury_2(:high)

  @impl AI.Model.Provider
  def smart(), do: mercury_2(:medium)

  @impl AI.Model.Provider
  def balanced(), do: mercury_2(:low)

  @impl AI.Model.Provider
  def fast(), do: mercury_2(:none)

  @impl AI.Model.Provider
  def web_search(), do: mercury_2(:none)

  @impl AI.Model.Provider
  def coding(), do: mercury_2(:low)

  @impl AI.Model.Provider
  def large_context(_tier), do: mercury_2()

  # Single model: mercury-2 at 128K context. supports_reasoning is
  # true so the request builder emits the per-profile reasoning_effort
  # on the wire; supports_web_search is false because there is no
  # provider-native web search and we do not have a sub-completion
  # search shim for Inception (callers should route to a different
  # provider for web search).
  def mercury_2(reasoning \\ :none) do
    AI.Model.new("mercury-2", 128_000, reasoning,
      supports_reasoning: true,
      supports_web_search: false
    )
  end
end

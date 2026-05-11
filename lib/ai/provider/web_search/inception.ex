defmodule AI.Provider.WebSearch.Inception do
  @moduledoc """
  Inception Labs implementation of the `AI.Provider.WebSearch` behaviour.

  Inception does not ship a web-search-capable model in their hosted
  catalog. Rather than spinning up a sub-completion against a model
  that cannot search, this implementation returns a clean
  unsupported-error so callers can route web search to a different
  provider (or feature-gate on `model.supports_web_search`).

  The behaviour is required for the provider dispatch in
  `AI.Provider.module_for(:web_search)`; the error-only implementation
  satisfies the contract without pretending to support a capability
  the provider lacks.
  """

  @behaviour AI.Provider.WebSearch

  @impl AI.Provider.WebSearch
  def search(query) when is_binary(query) do
    {:error,
     "Web search is not supported on Inception Labs. " <>
       "Switch to a provider whose `web_search` profile carries " <>
       "`supports_web_search: true` (OpenAI or Venice today)."}
  end
end

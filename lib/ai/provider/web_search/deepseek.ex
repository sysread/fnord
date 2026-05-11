defmodule AI.Provider.WebSearch.DeepSeek do
  @moduledoc """
  DeepSeek implementation of the `AI.Provider.WebSearch` behaviour.

  DeepSeek does not ship a web-search-capable model in their hosted
  catalog. The behaviour is required for provider dispatch in
  `AI.Provider.module_for(:web_search)`; this implementation returns
  a clean unsupported-error so callers can route web search to a
  different provider (or feature-gate on `model.supports_web_search`).
  """

  @behaviour AI.Provider.WebSearch

  @impl AI.Provider.WebSearch
  def search(query) when is_binary(query) do
    {:error,
     "Web search is not supported on DeepSeek. " <>
       "Switch to a provider whose `web_search` profile carries " <>
       "`supports_web_search: true` (OpenAI or Venice today)."}
  end
end

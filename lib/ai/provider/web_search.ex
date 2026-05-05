defmodule AI.Provider.WebSearch do
  @moduledoc """
  Behaviour for performing a web search via the active LLM provider.

  Web search is one of the few request shapes that varies wildly across
  providers - so wildly that hiding it behind a single chat-completion
  parameter (the way `AI.Provider.RequestBuilder` does for reasoning and
  tools) leaks too many provider-specific details into the orchestration
  layer.

  ## How providers differ

  - **OpenAI** has a small set of search-preview-class models. To search,
    you call one of those models with the `web_search_options` field set.
    Citations come back as inline plaintext URLs in the assistant message
    body. fnord runs this as a sub-completion: a second `AI.Completion`
    call, separate from the user's main conversation, with a hardcoded
    system prompt that asks the model to format results.

  - **Venice** has web search as a per-request flag on every model. You
    set `venice_parameters.enable_web_search` and `enable_web_citations`,
    and the search runs inline as part of the model's normal response.
    Citations come back as a structured array, with inline `^N^` markers
    in the response text pointing to entries in that array. No separate
    sub-completion is needed.

  ## The contract this behaviour exposes

  All consumers (today: `AI.Tools.WebSearch.call/1`) treat web search as
  "string in, string out." The implementation is free to do anything
  internally - sub-completion, inline call, RPC to a search service - as
  long as it returns a single textual result containing search content
  and any citations. The string is what gets fed back to the calling
  agent's conversation as the tool's output.

  ## Why this is a behaviour and not a top-level flag

  The original design had `AI.Completion.web_search?: true` as the only
  signal. That works fine for Venice (one extra param) but maps awkwardly
  to OpenAI (you need to *also* swap to a search-preview model). Pushing
  the strategy into a per-provider module lets each provider implement
  the right native pattern without the orchestration layer caring.
  """

  @doc """
  Perform a web search and return a textual result.

  The result string should be self-contained: any URLs, snippets, or
  citation markers needed to answer the query are embedded in the
  string. Callers use the return value verbatim as a tool output.

  Errors should surface as `{:error, reason}` where `reason` is a binary
  the orchestration layer can render to the user.
  """
  @callback search(query :: binary) :: {:ok, binary} | {:error, binary}
end

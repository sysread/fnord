defmodule AI.Provider.WebSearch.Venice do
  @moduledoc """
  Venice implementation of the `AI.Provider.WebSearch` behaviour.

  Runs a single inline `AI.Completion.get/1` call with `web_search?: true`
  against the configured Venice web-search profile. No sub-prompt loop
  is needed: Venice's `venice_parameters.enable_web_search` performs the
  search as part of the model's normal response, and the response
  parser appends the structured citations to the assistant text.

  ## Why this is so much simpler than the OpenAI implementation

  OpenAI gates web search to a small set of search-preview models, so
  the OpenAI implementation has to spin up a sub-completion against a
  dedicated model with a hardcoded prompt to format results. Venice
  treats web search as a per-request flag on any model, so the strategy
  collapses to "ask the search profile a question with web search on,
  return the answer."

  The downstream `AI.Tools.WebSearch` consumer treats this as a black
  box - "string in, string out" - so the difference in implementation
  effort never reaches the orchestration layer.
  """

  @behaviour AI.Provider.WebSearch

  @impl AI.Provider.WebSearch
  def search(query) when is_binary(query) do
    AI.Completion.get(
      model: AI.Model.web_search(),
      web_search?: true,
      messages: [
        AI.Util.system_msg(system_prompt()),
        AI.Util.user_msg(query)
      ]
    )
    |> case do
      {:ok, %{response: response}} ->
        # The response already includes the inline `^N^` citation
        # markers and the appended "Sources:" section produced by
        # `AI.Provider.ResponseParser.Venice`. No further processing
        # needed - the tool consumer treats this as opaque text.
        {:ok, response}

      {:error, :context_length_exceeded, _usage} ->
        {:error, "web search exceeded the context window"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  # Lighter-weight prompt than the OpenAI sub-completion's: Venice runs
  # the search inline as the model's normal response, and the response
  # parser handles citation formatting downstream. We just nudge the
  # model toward concision and toward including URLs in any direct
  # answer it produces.
  defp system_prompt do
    """
    You are answering a query that may benefit from up-to-date web information.
    A web search has been performed for you and the results are available in your context.
    Provide a concise, direct answer. When citing specific facts, reference the inline
    `^N^` markers; the full source list is appended automatically. If the query is open-
    ended (e.g. "find packages for X"), respond with a short list of relevant URLs.
    """
  end
end

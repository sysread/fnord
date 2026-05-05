defmodule AI.Provider.WebSearch.OpenAI do
  @moduledoc """
  OpenAI implementation of the `AI.Provider.WebSearch` behaviour.

  Runs the search as a *sub-completion*: a second `AI.Completion.get/1`
  call with a dedicated search-preview model and a hardcoded system
  prompt that instructs the model to format its results as either a list
  of relevant URLs (for open-ended queries) or a direct answer with
  inline citations (for focused queries).

  ## Why a sub-completion

  OpenAI's web search is gated to a small set of search-preview-class
  models. The active conversation's coordinator typically runs a
  different model, so we cannot just flip a flag on the existing
  request. The sub-completion approach lets us call `AI.Model.web_search()`
  for the duration of one search and return its formatted output as a
  tool result - without disturbing the main conversation's model.

  ## Citations

  OpenAI's search-preview models embed citations as plaintext URLs in
  the response body. The system prompt below asks the model to format
  results so URLs are visible and on their own. There is no structured
  citation array (Venice has that; OpenAI does not).
  """

  @behaviour AI.Provider.WebSearch

  @impl AI.Provider.WebSearch
  def search(query) when is_binary(query) do
    AI.Completion.get(
      model: AI.Model.web_search(),
      messages: [
        AI.Util.system_msg(system_prompt()),
        AI.Util.user_msg("Search the web for the following query: #{query}")
      ]
    )
    |> case do
      {:ok, %{response: response}} ->
        {:ok, response}

      # AI.Completion.get/1 reports context-window overflow as a three-
      # tuple with the usage count attached. Collapse it to a typed
      # :error so the tool caller contract stays single-shaped.
      {:error, :context_length_exceeded, _usage} ->
        {:error, "web search exceeded the context window"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  # The system prompt branches on the shape of the query. Open-ended
  # queries (e.g. "find packages for X") get a list of URLs; focused
  # queries (e.g. "how does function Y work in this site's API?") get
  # a direct answer with inline citations. Both shapes have explicit
  # templates so the response is consistent for downstream parsing.
  defp system_prompt do
    """
    You are a web search tool that provides concise and relevant information based on user queries.
    Use the provided query to search the web and return the most pertinent results.

    There are two separate response types, based on the query.

    # Search Query
    Examples:
    - "Find go packages for making HTTP requests"
    - "Search npm for packages related to image processing"

    Response template (without the code fences):
    ```
    - [url 1]: [Brief description of the first relevant result]
    - [url 2]: [Brief description of the second relevant result]
    - [url 3]: [Brief description of the third relevant result]
    - ...
    ```

    Do not include any explanations or additional text outside the response template.

    # Direct Answer Query
    Examples:
    - "Identify the API calls that perform user authentication in https://example.com/api-docs"
    - "How do you structure the tools list in this API? - https://example.com/api-docs"

    Response template (without the code fences):
    ```
    [Direct answer to the query based on the information found in the provided URL, with inline citations from the site's content when possible]
    ```

    """
  end
end

defmodule AI.Tools.WebSearch do
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: true

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def ui_note_on_request(%{"query" => query}) do
    {"Web search", query}
  end

  @impl AI.Tools
  def ui_note_on_result(%{"query" => query}, result) do
    {"Web search",
     """
     #{query}
     -----
     #{result}
     """}
  end

  @impl AI.Tools
  def read_args(args) do
    with {:ok, query} <- AI.Tools.get_arg(args, "query") do
      {:ok, %{"query" => query}}
    end
  end

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "web_search_tool",
        description: "Search the web for relevant information to answer user queries.",
        parameters: %{
          type: "object",
          required: ["query"],
          properties: %{
            query: %{
              type: "string",
              description: """
              The search query to find relevant information on the web.
              This may be an open-ended query to identify relevant web pages, or a specific question about a particular site.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(args) do
    with {:ok, query} <- AI.Tools.get_arg(args, "query") do
      perform_search(query)
    end
  end

  defp perform_search(query) do
    AI.Completion.get(
      model: AI.Model.web_search(),
      messages: [
        AI.Util.system_msg("""
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

        """),
        AI.Util.user_msg("Search the web for the following query: #{query}")
      ]
    )
    |> case do
      {:ok, %{response: response}} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end
end

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
              description: "The search query to find relevant information on the web."
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

        Response template (without the code fences):
        ```
        - [url 1]: [Brief description of the first relevant result]
        - [url 2]: [Brief description of the second relevant result]
        - [url 3]: [Brief description of the third relevant result]
        - ...
        ```

        Do not include any explanations or additional text outside the response template.
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

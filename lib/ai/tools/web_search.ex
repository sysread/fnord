defmodule AI.Tools.WebSearch do
  @moduledoc """
  Tool wrapper around the active provider's web search implementation.

  Implements the `AI.Tools` behaviour so the model can call
  `web_search_tool` from inside any conversation. The actual search
  strategy is delegated to whichever module the active provider's
  `AI.Provider.WebSearch` implementation points at - sub-completion on
  OpenAI, inline `venice_parameters` on Venice, or whatever future
  providers ship.

  Keeping the strategy out of this module means a third provider that
  implements web search differently (e.g. via an external SERP API) can
  plug in without touching this file.
  """

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
  def tool_call_failure_message(_args, _reason), do: :default

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
      # Dispatch to whichever web-search strategy the active provider
      # exposes. The strategy may run a separate sub-completion (OpenAI),
      # a single inline call (Venice), or anything else - this module
      # is deliberately ignorant.
      apply(AI.Provider.module_for(:web_search), :search, [query])
    end
  end
end

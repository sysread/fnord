defmodule AI.Tools.Conversation do
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: true

  @impl AI.Tools
  def is_available?(), do: match?({:ok, _}, Store.get_project())

  @impl AI.Tools
  def ui_note_on_request(%{"action" => "search", "query" => query}) do
    {"Conversation search", query}
  end

  def ui_note_on_request(%{"action" => "ask", "conversation_id" => id}) do
    {"Conversation QA", "Conversation id: #{id}"}
  end

  def ui_note_on_request(_), do: nil

  @impl AI.Tools
  def ui_note_on_result(%{"action" => "search"} = args, result) do
    query = Map.get(args, "query", "")
    {"Conversation search results",
     "Query: #{query}\nResults: #{inspect(result)}"}
  end

  def ui_note_on_result(%{"action" => "ask"} = args, result) do
    id = Map.get(args, "conversation_id", "")
    question = Map.get(args, "question", "")
    {"Conversation QA result",
     "Conversation id: #{id}\nQuestion: #{question}\nAnswer: #{inspect(result)}"}
  end

  def ui_note_on_result(_, _), do: nil

  @impl AI.Tools
  def tool_call_failure_message(_args, _reason), do: :default

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "conversation_tool",
        description: "Search conversations or ask questions about a specific conversation.",
        strict: true,
        parameters: %{
          type: "object",
          additionalProperties: false,
          required: ["action"],
          properties: %{
            "action" => %{
              type: "string",
              enum: ["search", "ask"],
              description: "Which operation to perform."
            },
            "query" => %{
              type: "string",
              description: "Search query for semantic conversation search (action=search)."
            },
            "limit" => %{
              type: "integer",
              description: "Max number of search results.",
              default: 5
            },
            "conversation_id" => %{
              type: "string",
              description: "Conversation id to ask about (action=ask)."
            },
            "question" => %{
              type: "string",
              description: "Question about the specified conversation (action=ask)."
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(%{"action" => "search"} = args), do: do_search(args)
  def call(%{"action" => "ask"} = args), do: do_ask(args)

  defp do_search(%{"query" => query} = args) do
    limit = Map.get(args, "limit", 5)

    with {:ok, project} <- Store.get_project(),
         {:ok, results} <- Search.Conversations.search(project, query, limit: limit) do
      {:ok, results}
    end
  end

  defp do_search(_), do: {:error, "Missing required field 'query' for action 'search'"}

  defp do_ask(%{"conversation_id" => id, "question" => question}) do
    agent = AI.Agent.new(AI.Agent.ConversationQA, [])

    case AI.Agent.get_response(agent, %{conversation_id: id, question: question}) do
      {:ok, answer} -> {:ok, answer}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp do_ask(_),
    do: {:error, "Missing required fields 'conversation_id' and 'question' for action 'ask'"}
end

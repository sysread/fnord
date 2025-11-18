defmodule AI.Tools.Conversation do
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: true

  @impl AI.Tools
  def is_available?(), do: match?({:ok, _}, Store.get_project())

  @impl AI.Tools
  def ui_note_on_request(%{"action" => "search", "query" => query}) do
    {"Searching past conversations", query}
  end

  def ui_note_on_request(%{"action" => "ask", "conversation_id" => id, "query" => query}) do
    {"Recalling past conversation", "(#{id}) #{query}"}
  end

  def ui_note_on_request(_), do: nil

  @impl AI.Tools
  def ui_note_on_result(%{"action" => "search"} = args, result) do
    query = Map.get(args, "query", "")

    titles =
      result
      |> Jason.decode!()
      |> Enum.map(fn %{"conversation_id" => id, "title" => title} ->
        title =
          if String.contains?(title, "\n") do
            title
            |> String.split("\n")
            |> List.first()
            |> then(&(&1 <> "..."))
          else
            title
          end

        "- [#{id}] #{title}"
      end)
      |> Enum.join("\n")

    {"Searched past conversations",
     """
     # #{query}

     #{titles}
     """}
  end

  def ui_note_on_result(%{"action" => "ask"} = args, result) do
    id = Map.get(args, "conversation_id", "")
    question = Map.get(args, "question", "")

    {"Recalled past conversation",
     """
     # (#{id}) #{question}

     #{result}
     """}
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
        description: """
        This tool allows you to perform a semantic search through past
        discussions that you have had with the user. Once you find a relevant
        conversation, you can ask specific questions about it and an AI agent
        will extract the relevant information from the conversation for you.
        """,
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

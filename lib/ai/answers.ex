defmodule AI.Answers do
  @moduledoc """
  This module provides an agent that answers questions by searching a database
  of information about the user's project. It uses a search tool to find
  matching files and their contents in order to generate a complete and concise
  answer for the user.
  """

  @model "gpt-4o"
  @prompt """
  You are a conversational interface to a database of information about the
  user's project. The database may contain:

  ### Code files:
    - **Synopsis**
    - **Languages present in the file**
    - **Business logic and behaviors**
    - **List of symbols**
    - **Map of calls to other modules**

  ### Documentation files (e.g., README, wiki pages, general documentation):
    - **Synopsis**: A brief overview of what the document covers.
    - **Topics and Sections**: A list of main topics or sections in the document.
    - **Definitions and Key Terms**: Any specialized terms or jargon defined in the document.
    - **Links and References**: Important links or references included in the document.
    - **Key Points and Highlights**: Main points or takeaways from the document.

  The user will prompt you with a question. You will use your `search_tool` to
  search the database in order to gain enough knowledge to answer the question
  as completely as possible. It may require multiple searches before you have
  all of the information you need.

  Once you have all of the information you need, provide the user with a
  complete yet concise answer, including generating any requested code or
  producing on-demand documentation by assimilating the information you have
  gathered.

  By default, answer as tersely as possible. Increase your verbosity in
  proportion to the specificity of the question.

  ALWAYS finish your response with a list of the relevant files that you found.
  Exclude files that are not relevant to the user's question. Format them as a
  list, where each file name is bolded and is followed by a colon and an
  explanation of how it is relevant. Err on the side of inclusion if you are
  unsure.
  """

  @search_tool %{
    type: "function",
    function: %{
      name: "search_tool",
      description: "searches for matching files and their contents",
      parameters: %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            description: "The search query string."
          }
        },
        required: ["query"]
      }
    }
  }

  def system_message() do
    OpenaiEx.ChatMessage.system(@prompt)
  end

  def assistant_message(msg) do
    OpenaiEx.ChatMessage.assistant(msg)
  end

  def assistant_tool_message(id, func, args) do
    %{
      role: "assistant",
      content: nil,
      tool_calls: [
        %{
          id: id,
          type: "function",
          function: %{
            name: func,
            arguments: args
          }
        }
      ]
    }
  end

  def user_message(msg) do
    OpenaiEx.ChatMessage.user(msg)
  end

  def tool_message(id, func, output) do
    OpenaiEx.ChatMessage.tool(id, func, output)
  end

  def stream(ai, messages) do
    chat_req =
      OpenaiEx.Chat.Completions.new(
        model: @model,
        tools: [@search_tool],
        tool_choice: "auto",
        messages: messages
      )

    {:ok, chat_stream} = OpenaiEx.Chat.Completions.create(ai.client, chat_req, stream: true)

    chat_stream.body_stream
  end
end

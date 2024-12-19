defmodule Cmd.Conversations do
  def run(opts) do
    cols = Owl.IO.columns()

    question = opts[:question]
    file = opts[:file]

    Store.list_conversations()
    |> case do
      [] ->
        IO.puts("No conversations found.")

      conversations ->
        conversations
        |> Enum.each(fn conversation ->
          out = [IO.ANSI.format([:green, conversation.id, :reset])]

          out =
            if file do
              [IO.ANSI.format([:cyan, conversation.store_path, :reset]) | out]
            else
              out
            end

          out =
            if question do
              taken = String.length(conversation.id) + 3

              taken =
                if file do
                  taken + String.length(conversation.store_path) + 3
                else
                  taken
                end

              {:ok, question} = Store.Conversation.question(conversation)
              [IO.ANSI.format([:cyan, ellipsis(question, cols - taken), :reset]) | out]
            else
              out
            end

          out
          |> Enum.reverse()
          |> Enum.join(" | ")
          |> IO.puts()
        end)
    end
  end

  defp ellipsis(str, limit) do
    if String.length(str) > limit do
      String.slice(str, 0, limit - 3) <> "..."
    else
      str
    end
  end
end

defmodule Cmd.Conversations do
  @behaviour Cmd

  @impl Cmd
  def spec do
    [
      conversations: [
        name: "conversations",
        about: "List all conversations in the project",
        options: [
          project: [
            value_name: "PROJECT",
            long: "--project",
            short: "-p",
            help: "Project name",
            required: true
          ]
        ],
        flags: [
          file: [
            long: "--file",
            short: "-f",
            help: "Print the path to the conversation file"
          ],
          question: [
            long: "--question",
            short: "-q",
            help: "include the question prompting the conversation"
          ]
        ]
      ]
    ]
  end

  @impl Cmd
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

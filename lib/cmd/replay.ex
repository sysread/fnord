defmodule Cmd.Replay do
  @behaviour Cmd

  @impl Cmd
  def spec() do
    [
      replay: [
        name: "replay",
        about: "Replay a conversation",
        options: [
          project: [
            value_name: "PROJECT",
            long: "--project",
            short: "-p",
            help: "Project name",
            required: true
          ],
          conversation: [
            value_name: "CONVERSATION",
            long: "--conversation",
            short: "-c",
            help: "The id of the conversation to replay",
            required: true
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(opts, _subcommands, _unknown) do
    with {:ok, conversation_id} <- Map.fetch(opts, :conversation),
         {:ok, conversation} <- get_conversation(conversation_id),
         {:ok, completion} <- get_completion(conversation) do
      AI.Completion.Output.replay_conversation_as_output(completion)
    end
  end

  defp get_conversation(conversation_id) do
    conversation = Store.Project.Conversation.new(conversation_id)

    if Store.Project.Conversation.exists?(conversation) do
      {:ok, conversation}
    else
      {:error, :conversation_not_found}
    end
  end

  defp get_completion(conversation) do
    AI.Completion.new_from_conversation(conversation,
      model: "n/a",
      log_msgs: true,
      log_tool_calls: true,
      replay_conversation: true
    )
  end
end

defmodule Cmd.Replay do
  @behaviour Cmd

  @impl Cmd
  def requires_project?(), do: true

  @impl Cmd
  def spec() do
    [
      replay: [
        name: "replay",
        about: "Replay a conversation",
        options: [
          project: Cmd.project_arg(),
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
    else
      # Surface the failure to the user. Cmd.perform_command doesn't print
      # :error returns, so a silent exit was the old behavior when an id
      # pointed at a conversation that doesn't exist in the selected
      # project's store.
      :error ->
        UI.error("Replay", "--conversation/-c is required")
        {:error, :missing_conversation}

      {:error, :conversation_not_found} ->
        conversation_id = Map.get(opts, :conversation)

        project =
          case Settings.get_selected_project() do
            {:ok, name} -> name
            _ -> "<unset>"
          end

        UI.error(
          "Replay",
          "Conversation #{inspect(conversation_id)} not found in project #{project}. " <>
            "List recent conversations with `fnord conversations -p #{project}`."
        )

        {:error, :conversation_not_found}
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

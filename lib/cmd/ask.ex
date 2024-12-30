defmodule Cmd.Ask do
  @project_not_found_error "Project not found; verify that the project has been indexed."

  @behaviour Cmd

  @impl Cmd
  def spec() do
    [
      ask: [
        name: "ask",
        about: "Ask the AI a question about the project",
        options: [
          project: [
            value_name: "PROJECT",
            long: "--project",
            short: "-p",
            help: "Project name",
            required: true
          ],
          question: [
            value_name: "QUESTION",
            long: "--question",
            short: "-q",
            help: "The prompt to ask the AI",
            required: true
          ],
          workers: [
            value_name: "WORKERS",
            long: "--workers",
            short: "-w",
            help: "Number of concurrent workers to use",
            parser: :integer,
            default: Cmd.default_workers()
          ],
          include: [
            value_name: "FILE",
            long: "--include",
            short: "-i",
            help: "Include a file in your prompt",
            multiple: true
          ],
          follow: [
            long: "--follow",
            short: "-f",
            help: "Follow up the conversation with another question/prompt"
          ]
        ],
        flags: [
          replay: [
            long: "--replay",
            short: "-r",
            help: "Replay a conversation (with --follow is set)"
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(opts) do
    with :ok <- validate(opts) do
      opts = Map.put(opts, :conversation, get_conversation(opts))
      AI.Agent.Answers.get_response(AI.new(), opts)
    else
      {:error, :project_not_found} -> UI.error(@project_not_found_error)
    end
  end

  defp validate(_opts) do
    Store.get_project()
    |> Store.Project.exists_in_store?()
    |> case do
      true -> :ok
      false -> {:error, :project_not_found}
    end
  end

  defp get_conversation(%{follow: nil}) do
    Store.Conversation.new()
  end

  defp get_conversation(%{follow: conversation_id}) do
    Store.Conversation.new(conversation_id)
  end
end

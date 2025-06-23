defmodule Cmd.Default do
  @moduledoc """
  Converses with the default AI agent.

  Conversations are a "floating window" of messages that are stored in the
  default project.
  """

  @behaviour Cmd

  @impl Cmd
  def spec() do
    [
      default: [
        name: "default",
        about: """
        Converse with the default AI agent. This feature is *alpha* and not
        fully functional yet. It uses the current directory to determine
        whether it is within a project context. If it's within a project, it
        can use the research tools, but it cannot yet access the project's
        notes or past research. Please open an issue if you notice any bugs.
        """,
        options: [
          prompt: [
            value_name: "PROMPT",
            long: "--prompt",
            short: "-p",
            help: "The prompt to ask the AI",
            required: true
          ]
        ]
      ]
    ]
  end

  @impl Cmd
  def run(opts, _subcommands, _unknown) do
    with {:ok, prompt} <- Map.fetch(opts, :prompt),
         {:ok, result} <- AI.Agent.Default.get_response(%{prompt: prompt}) do
      IO.puts(result.response)
      IO.puts("")
      maybe_rollup(result.usage, result.num_msgs)
    else
      :error -> IO.puts("Error: Missing required option --prompt")
    end
  end

  # ----------------------------------------------------------------------------
  # Rollups: Archive older messages as a summary when the size of the
  # conversation exceeds a threshold based on the model's context window.
  # ----------------------------------------------------------------------------
  @rollup_prompt """
  The conversation is beginning to fill the context window. Would you like to
  archive older messages? Older messages will be archived as a monthly summary
  for reference. The AI will continue to have access to those summaries.
  """

  @rollup_context_threshold 0.1

  defp maybe_rollup(usage, num_msgs) do
    UI.log_usage(AI.Agent.Default.model(), usage)
    UI.info("Conversation length: #{num_msgs} messages")

    if usage / AI.Agent.Default.model().context > @rollup_context_threshold do
      if UI.confirm(@rollup_prompt) do
        last_interaction = Store.DefaultProject.Conversation.last_interaction()

        AI.Agent.Default.Rollups.get_response(%{})
        |> case do
          {:ok, summaries} ->
            Store.DefaultProject.Conversation.replace_messages(summaries ++ last_interaction)
            UI.info("Summarized and archived older messages.")

          {:error, reason} ->
            UI.error("Failed to generate summaries: #{reason}")
        end
      else
        UI.info("Conversation not consolidated.")
      end
    end
  end
end

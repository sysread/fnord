defmodule Cmd.Default do
  @moduledoc """
  Converses with the default AI agent.

  Conversations are a "floating window" of messages that are stored in the
  default project.
  """

  @behaviour Cmd

  @impl Cmd
  def requires_project?, do: false

  @impl Cmd
  def spec() do
    [
      default: [
        name: "default",
        about: """
        Converse with the default AI agent. This feature is *alpha* and not
        fully functional yet. It uses the current directory to determine
        whether it is within a project context. If called from within a
        previously indexed project's directory, it can use the research tools,
        but it cannot yet access the project's notes or past research. Please
        open an issue if you notice any bugs.

        Usage: fnord "<prompt>"
        """
      ]
    ]
  end

  @impl Cmd
  def run(_opts, _subcommands, []) do
    IO.puts(:stderr, "Error: Missing required positional argument 'prompt'.")
  end

  def run(_opts, _subcommands, [prompt]) do
    with {:ok, result} <- AI.Agent.Default.get_response(%{prompt: prompt}) do
      IO.puts(result.response)
      IO.puts("")
      UI.flush()
      maybe_rollup(result.usage, result.num_msgs)
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

  @rollup_context_threshold 0.5

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

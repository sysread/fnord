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
        Converse with the default AI agent.
        This feature is *alpha* and not fully functional yet.
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

      UI.log_usage(AI.Agent.Default.model(), result.usage)
      UI.info("Conversation length: #{result.num_msgs} messages")
    else
      :error -> IO.puts("Error: Missing required option --prompt")
    end
  end
end

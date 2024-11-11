defmodule Ask do
  defstruct [
    :ai,
    :opts,
    :agent,
    :buffer
  ]

  def new(opts) do
    ai = AI.new()
    agent = AI.Agent.Answers.new(ai, opts)
    %Ask{ai: ai, opts: opts, agent: agent, buffer: ""}
  end

  def run(ask) do
    with {:ok, output} <- AI.Agent.Answers.perform(ask.agent) do
      UI.puts("----------------------------------------")
      UI.puts(output)
    end
  end
end

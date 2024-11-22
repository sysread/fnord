defmodule Cmd.Ask do
  def run(opts) do
    AI.Agent.Answers.perform(AI.new(), opts)
  end
end

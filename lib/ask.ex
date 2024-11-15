defmodule Ask do
  def run(opts) do
    {:ok, tui} = Tui.start_link(opts)

    agent = AI.Agent.Answers.new(AI.new(), opts)

    with {:ok, output} <- AI.Agent.Answers.perform(agent) do
      Tui.stop(tui)

      Owl.IO.puts("")
      Owl.IO.puts(output)
    end
  end
end

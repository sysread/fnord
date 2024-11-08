defmodule Ask do
  defstruct [
    :ai,
    :opts,
    :agent
  ]

  def new(opts) do
    ai = AI.new()
    agent = AI.Agent.Answers.new(ai, opts, &update_answer/2)
    %Ask{ai: ai, opts: opts, agent: agent}
  end

  def run(ask) do
    start_output()
    AI.Agent.Answers.perform(ask.agent)
    end_output()
  end

  # -----------------------------------------------------------------------------
  # IO
  # -----------------------------------------------------------------------------
  def interactive?() do
    IO.ANSI.enabled?()
  end

  defp start_output() do
    if interactive?() do
      Owl.Spinner.start(id: :status)
      Owl.LiveScreen.add_block(:answer, state: "")
    end
  end

  defp end_output() do
    if interactive?() do
      Owl.Spinner.stop(id: :status, resolution: :ok, label: "Answer received")
      Owl.IO.puts("")
    else
      IO.puts("")
    end
  end

  def update_status(msg) do
    if interactive?() do
      Owl.Spinner.update_label(id: :status, label: msg)
      Owl.LiveScreen.await_render()
    end
  end

  def update_answer(chunk, buffer) do
    if interactive?() do
      Owl.LiveScreen.update(:answer, buffer)
      Owl.LiveScreen.await_render()
    else
      IO.write(chunk)
    end
  end
end

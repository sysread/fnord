defmodule Ask do
  defstruct [
    :ai,
    :opts,
    :agent
  ]

  def new(opts) do
    on_msg_chunk =
      if interactive?() do
        fn _chunk, buffer ->
          Owl.LiveScreen.update(:answer, buffer)
          Owl.LiveScreen.await_render()
        end
      else
        fn chunk, _buffer ->
          IO.write(chunk)
        end
      end

    ai = AI.new()
    agent = AI.AnswersAgent.new(ai, opts, on_msg_chunk)

    %Ask{
      ai: ai,
      opts: opts,
      agent: agent
    }
  end

  def run(ask) do
    start_output()
    get_answer(ask)
    end_output()
  end

  # -----------------------------------------------------------------------------
  # IO
  # -----------------------------------------------------------------------------
  defp interactive?() do
    IO.ANSI.enabled?()
  end

  defp get_answer(ask) do
    AI.AnswersAgent.perform(ask.agent)
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
end

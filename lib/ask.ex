defmodule Ask do
  defstruct [
    :ai,
    :opts,
    :agent
  ]

  def new(opts) do
    on_msg_chunk =
      if opts.quiet do
        fn chunk, _buffer ->
          IO.write(chunk)
        end
      else
        fn _chunk, buffer ->
          Owl.LiveScreen.update(:answer, buffer)
          Owl.LiveScreen.await_render()
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
    ask
    |> start_output()
    |> get_answer()
    |> end_output()
  end

  defp get_answer(ask) do
    AI.AnswersAgent.perform(ask.agent)
  end

  defp start_output(%Ask{opts: %{quiet: true}} = ask) do
    ask
  end

  defp start_output(ask) do
    Owl.LiveScreen.add_block(:answer, state: "Assistant is thinking...")
    ask
  end

  defp end_output(%Ask{opts: %{quiet: true}} = ask) do
    IO.puts("")
    ask
  end

  defp end_output(ask) do
    Owl.IO.puts("")
    ask
  end
end

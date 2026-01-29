defmodule Spinner do
  @spinner_id :fnord

  @bullshit_rotation_interval 2500

  @bullshit_sf_phrases [
    "Reversing the polarity of the context window",
    "Recalibrating the embedding matrix flux",
    "Initializing quantum token shuffler",
    "Stabilizing token interference",
    "Aligning latent vector manifold",
    "Charging semantic field resonator",
    "Inverting prompt entropy",
    "Redirecting gradient descent pathways",
    "Synchronizing the decoder attention",
    "Calibrating neural activation dampener",
    "Polarizing self-attention mechanism",
    "Recharging photonic energy in the deep learning nodes",
    "Fluctuating the vector space harmonics",
    "Boosting the backpropagation neutrino field",
    "Cross-referencing the hallucination core",
    "Reticulating splines"
  ]

  @spec run(fun :: (-> {String.t() | nil, any}), label :: iodata()) :: any
  def run(fun, label) do
    Process.put(:stop_label, "Done")

    try do
      # Attempt to print label; ignore if Owl.IO.puts not available
      try do
        Owl.IO.puts(label)
      rescue
        _ -> :noop
      catch
        :exit, :noproc -> :noop
        _, _ -> :noop
      end

      # Attempt to start spinner; ignore if spinner not available
      try do
        Owl.Spinner.start(id: @spinner_id)
      rescue
        _ -> :noop
      catch
        :exit, :noproc -> :noop
        _, _ -> :noop
      end

      start_label_changer()

      {msg0, result} = fun.()
      Process.put(:stop_label, if(is_nil(msg0), do: "Done", else: msg0))
      result
    after
      # Always attempt to stop spinner to avoid leaks
      try do
        Owl.Spinner.stop(id: @spinner_id, resolution: :ok, label: Process.get(:stop_label))
      rescue
        _ -> :noop
      catch
        :exit, :noproc -> :noop
        _, _ -> :noop
      end
    end
  end

  @spec start_label_changer() :: {:ok, pid()}
  defp start_label_changer() do
    Task.start(fn ->
      phrases = Enum.shuffle(@bullshit_sf_phrases)

      try do
        Enum.each(phrases, fn phrase ->
          try do
            Owl.Spinner.update_label(id: @spinner_id, label: phrase)
            Process.sleep(@bullshit_rotation_interval)
          rescue
            _ -> :noop
          catch
            :exit, :noproc -> throw(:stop)
            _, _ -> :noop
          end
        end)

        # Restart the cycle after completing the list
        start_label_changer()
      catch
        :stop -> :ok
      end
    end)
  end
end

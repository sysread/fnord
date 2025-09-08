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

  def run(fun, label) do
    Owl.IO.puts(label)
    Owl.Spinner.start(id: @spinner_id)
    start_label_changer()
    {msg, result} = fun.()
    msg = if is_nil(msg), do: "Done", else: msg
    Owl.Spinner.stop(id: @spinner_id, resolution: :ok, label: msg)
    result
  end

  defp start_label_changer() do
    Task.start(fn ->
      phrases = Enum.shuffle(@bullshit_sf_phrases)

      Enum.each(phrases, fn phrase ->
        Owl.Spinner.update_label(id: @spinner_id, label: phrase)
        Process.sleep(@bullshit_rotation_interval)
      end)

      # Restart the cycle after completing the list
      start_label_changer()
    end)
  end
end

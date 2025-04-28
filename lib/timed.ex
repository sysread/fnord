defmodule Timed do
  require Logger

  def timed(name, fun) do
    {time_us, result} = :timer.tc(fun)
    time_s = (time_us / 1_000_000) |> Float.round(3)
    UI.info(name, "Took #{time_s} seconds")
    result
  end
end

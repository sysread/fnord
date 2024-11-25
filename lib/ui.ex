defmodule UI do
  require Logger

  def flush do
    unless quiet?() do
      Logger.flush()
    end
  end

  def report_step(msg, detail) do
    unless quiet?() do
      Logger.info(IO.ANSI.format([:green, msg, :reset, ": ", :cyan, detail, :reset], colorize?()))
    end
  end

  def report_step(msg) do
    unless quiet?() do
      Logger.info(IO.ANSI.format([:green, msg, :reset], colorize?()))
    end
  end

  def debug_msg(msg) do
    unless quiet?() do
      Logger.debug(IO.ANSI.format([:green, msg, :reset, colorize?()]))
    end
  end

  def warn(msg, detail) do
    unless quiet?() do
      Logger.warning(
        IO.ANSI.format([:yellow, msg, :reset, ": ", :cyan, detail, :reset], colorize?())
      )
    end
  end

  def warn(msg) do
    unless quiet?() do
      Logger.warning(IO.ANSI.format([:yellow, msg, :reset, colorize?()]))
    end
  end

  defp colorize? do
    :prim_tty.isatty(:stderr)
  end

  defp quiet? do
    Application.get_env(:fnord, :quiet, false)
  end
end

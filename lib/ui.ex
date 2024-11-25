defmodule UI do
  require Logger

  def flush do
    Logger.flush()
  end

  def report_step(msg) do
    Logger.info(IO.ANSI.format([:green, msg, :reset], colorize?()))
  end

  def report_step(msg, detail) do
    Logger.info(IO.ANSI.format([:green, msg, :reset, ": ", :cyan, detail, :reset], colorize?()))
  end

  def debug(msg) do
    Logger.debug(IO.ANSI.format([:green, msg, :reset], colorize?()))
  end

  def debug(msg, detail) do
    Logger.debug(IO.ANSI.format([:green, msg, :reset, ": ", :cyan, detail, :reset], colorize?()))
  end

  def warn(msg) do
    Logger.warning(IO.ANSI.format([:yellow, msg, :reset], colorize?()))
  end

  def warn(msg, detail) do
    Logger.warning(
      IO.ANSI.format([:yellow, msg, :reset, ": ", :cyan, detail, :reset], colorize?())
    )
  end

  def error(msg) do
    Logger.error(IO.ANSI.format([:red, msg, :reset], colorize?()))
  end

  def error(msg, detail) do
    Logger.error(IO.ANSI.format([:red, msg, :reset, ": ", :cyan, detail, :reset], colorize?()))
  end

  defp colorize? do
    :prim_tty.isatty(:stderr)
  end
end

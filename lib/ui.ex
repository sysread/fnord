defmodule UI do
  require Logger

  def report_step(msg, detail) do
    Logger.info(IO.ANSI.format([:green, msg, :reset, ": ", :cyan, detail, :reset], colorize?()))
  end

  def report_step(msg) do
    Logger.info(IO.ANSI.format([:green, msg, :reset], colorize?()))
  end

  def debug_msg(msg) do
    Logger.debug(IO.ANSI.format([:yellow, msg, :reset, colorize?()]))
  end

  def colorize? do
    :prim_tty.isatty(:stderr)
  end
end

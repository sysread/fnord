defmodule UI do
  require Logger

  # ----------------------------------------------------------------------------
  # Messaging
  # ----------------------------------------------------------------------------
  def confirm(msg), do: confirm(msg, false)

  def confirm(_msg, true), do: true

  def confirm(msg, _default) do
    IO.write("#{msg} (y/n) ")

    case IO.gets("") do
      "y\n" -> true
      "Y\n" -> true
      _ -> false
    end
  end

  def flush do
    Logger.flush()
  end

  def report_step(msg), do: info(msg)
  def report_step(msg, detail), do: info(msg, detail)

  def begin_step(msg, detail \\ nil) do
    if is_nil(detail) do
      Logger.info(IO.ANSI.format([:green, msg, :reset], colorize?()))
    else
      Logger.info(IO.ANSI.format([:green, msg, :reset, ": ", :cyan, detail, :reset], colorize?()))
    end
  end

  def end_step(msg, detail \\ nil) do
    if is_nil(detail) do
      Logger.info(IO.ANSI.format([:yellow, msg, :reset], colorize?()))
    else
      Logger.info(
        IO.ANSI.format([:yellow, msg, :reset, ": ", :cyan, detail, :reset], colorize?())
      )
    end
  end

  def inspect(item, label) do
    Logger.debug(label, Kernel.inspect(item, pretty: true, binaries: :as_strings))
    Logger.flush()
    item
  end

  def debug(msg) do
    Logger.debug(IO.ANSI.format([:green, msg, :reset], colorize?()))
  end

  def debug(msg, detail) do
    Logger.debug(IO.ANSI.format([:green, msg, :reset, ": ", :cyan, detail, :reset], colorize?()))
  end

  def info(msg) do
    Logger.info(IO.ANSI.format([:green, msg, :reset], colorize?()))
  end

  def info(msg, detail) do
    msg = msg || ""
    detail = detail || ""
    Logger.info(IO.ANSI.format([:green, msg, :reset, ": ", :cyan, detail, :reset], colorize?()))
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
    |> case do
      true -> true
      _ -> false
    end
  end

  # ----------------------------------------------------------------------------
  # Interactive elements
  # ----------------------------------------------------------------------------
  def quiet?() do
    Application.get_env(:fnord, :quiet)
  end

  def spin(processing, func) do
    if quiet?() do
      info(processing)
      {_msg, result} = func.()
      result
    else
      Spinner.run(func, processing)
    end
  end

  def progress_bar_start(name, label, total) do
    if !quiet?() do
      Owl.ProgressBar.start(
        id: name,
        label: label,
        total: total,
        timer: true,
        absolute_values: true
      )
    end
  end

  def progress_bar_update(name) do
    if !quiet?() do
      Owl.ProgressBar.inc(id: name)
      Owl.LiveScreen.await_render()
    end
  end

  def start_in_progress_jobs_monitor(queue, finished_str) do
    if UI.quiet?() do
      Task.async(fn -> :ok end)
    else
      Owl.LiveScreen.add_block(:in_progress, state: "")

      Task.async(fn ->
        in_progress_jobs(queue)
        Owl.LiveScreen.update(:in_progress, finished_str)
        Owl.LiveScreen.await_render()
      end)
    end
  end

  defp in_progress_jobs(queue) do
    cols = Owl.IO.columns() || 80

    unless Queue.is_idle(queue) do
      jobs =
        queue
        |> Queue.in_progress_jobs()
        |> Enum.map(fn job ->
          try do
            "- #{job.rel_path}"
          rescue
            _ ->
              # -9 for ellipsis (3), leading space+dash (2), and the box's
              # padding (1 for left + 1 for right).
              job
              |> String.slice(0, cols - 9)
              |> case do
                ^job -> "- #{job}"
                slice -> "- #{slice}..."
              end
          end
        end)
        |> Enum.join("\n")

      box =
        Owl.Box.new(jobs,
          title: "[ In Progress ]",
          border_style: :solid_rounded,
          horizontal_aling: :left,
          padding_x: 1
        )

      Owl.LiveScreen.update(:in_progress, box)

      Process.sleep(250)
      in_progress_jobs(queue)
    end
  end
end

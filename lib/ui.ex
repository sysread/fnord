defmodule UI do
  require Logger

  # ----------------------------------------------------------------------------
  # Messaging
  # ----------------------------------------------------------------------------
  def say(msg) do
    UI.flush()

    msg
    |> UI.Formatter.format_output()
    |> IO.puts()
  end

  @spec confirm(binary) :: boolean
  def confirm(msg), do: confirm(msg, false)

  @spec confirm(binary, boolean) :: boolean
  def confirm(msg, default) do
    has_default = is_boolean(default)

    cond do
      is_tty?() ->
        yes = if default == true, do: "Y", else: "y"
        no = if default == false, do: "N", else: "n"

        flush()
        IO.write(:stderr, UI.Formatter.format_output("#{msg} (#{yes}/#{no}) "))

        case IO.gets("") do
          "y\n" -> true
          "Y\n" -> true
          _ -> default
        end

      has_default ->
        default

      true ->
        Logger.warning(
          "Confirmation requested without default, but session is not connected to a TTY."
        )

        false
    end
  end

  def flush, do: Logger.flush()

  def report_step(msg), do: info(msg)
  def report_step(msg, detail), do: info(msg, detail)

  def begin_step(msg, detail \\ nil) do
    if is_nil(detail) do
      Logger.info(IO.ANSI.format([:green, msg, :reset], colorize?()))
    else
      Logger.info(
        IO.ANSI.format(
          [:green, msg, :reset, ": ", :cyan, clean_detail(detail), :reset],
          colorize?()
        )
      )
    end
  end

  def end_step(msg, detail \\ nil) do
    if is_nil(detail) do
      Logger.info(IO.ANSI.format([:yellow, msg, :reset], colorize?()))
    else
      Logger.info(
        IO.ANSI.format(
          [:yellow, msg, :reset, ": ", :cyan, clean_detail(detail), :reset],
          colorize?()
        )
      )
    end
  end

  def printf_debug(item) do
    Logger.debug(inspect(item, pretty: true))
    Logger.flush()
    item
  end

  def debug(msg) do
    Logger.debug(IO.ANSI.format([:green, msg, :reset], colorize?()))
  end

  def debug(msg, detail) do
    Logger.debug(
      IO.ANSI.format(
        [:green, msg, :reset, ": ", :cyan, clean_detail(detail), :reset],
        colorize?()
      )
    )
  end

  def info(msg) do
    Logger.info(IO.ANSI.format([:green, msg, :reset], colorize?()))
  end

  def info(msg, detail) do
    msg = msg || ""

    Logger.info(
      IO.ANSI.format(
        [:green, msg, :reset, ": ", :cyan, clean_detail(detail), :reset],
        colorize?()
      )
    )
  end

  def warn(msg) do
    Logger.warning(IO.ANSI.format([:yellow, msg, :reset], colorize?()))
  end

  def warn(msg, detail) do
    Logger.warning(
      IO.ANSI.format(
        [:yellow, msg, :reset, ": ", :cyan, clean_detail(detail), :reset],
        colorize?()
      )
    )
  end

  def error(msg) do
    Logger.error(IO.ANSI.format([:red, msg, :reset], colorize?()))
  end

  def error(msg, detail) do
    Logger.error(
      IO.ANSI.format([:red, msg, :reset, ": ", :cyan, clean_detail(detail), :reset], colorize?())
    )
  end

  def warning_banner(msg) do
    IO.puts(
      :stderr,
      IO.ANSI.format(
        [
          :red_background,
          :black,
          " <<< WARNING >>> #{msg} <<< WARNING >>> ",
          :reset
        ],
        colorize?()
      )
    )
  end

  @spec fatal(binary) :: no_return()
  def fatal(msg) do
    Logger.error(IO.ANSI.format([:red, msg, :reset], colorize?()))
    Logger.flush()
    System.halt(1)
  end

  @spec fatal(binary, binary) :: no_return()
  def fatal(msg, detail) do
    Logger.error(
      IO.ANSI.format([:red, msg, :reset, ": ", :cyan, clean_detail(detail), :reset], colorize?())
    )

    Logger.flush()
    System.halt(1)
  end

  @spec log_usage(AI.Model.t(), non_neg_integer) :: :ok
  def log_usage(model, usage) when is_integer(usage) do
    percentage = Float.round(usage / model.context * 100, 2)
    str_usage = Util.format_number(usage)
    str_context = Util.format_number(model.context)
    info("Context window usage", "#{percentage}% (#{str_usage} / #{str_context} tokens)")
  end

  def is_tty? do
    :prim_tty.isatty(:stderr)
    |> case do
      true -> true
      _ -> false
    end
  end

  def colorize?, do: is_tty?()

  def italicize(text) do
    IO.ANSI.format([:italic, text, :reset], colorize?())
  end

  # ----------------------------------------------------------------------------
  # Interactive elements
  # ----------------------------------------------------------------------------
  def quiet?() do
    Application.get_env(:fnord, :quiet)
  end

  def spin(processing, func) do
    if quiet?() do
      begin_step(processing)
      {msg, result} = func.()
      end_step(msg)
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

  def async_stream(enumerable, fun, label \\ "Working", options \\ []) do
    progress_bar_start(:async_stream, label, Enum.count(enumerable))

    enumerable
    |> Util.async_stream(
      fn item ->
        result = fun.(item)
        progress_bar_update(:async_stream)
        result
      end,
      options
    )
  end

  def choose(prompt, options, owl_opts \\ []) do
    prompt |> UI.Formatter.format_output() |> IO.puts()
    Owl.IO.select(options, owl_opts)
  end

  def prompt(prompt, owl_opts \\ []) do
    prompt |> UI.Formatter.format_output() |> IO.puts()
    Owl.IO.input(owl_opts)
  end

  def clean_detail(nil), do: ""

  def clean_detail(detail) do
    if iodata?(detail) do
      detail
    else
      inspect(detail, pretty: true, limit: :infinity)
    end
    |> IO.ANSI.format(colorize?())
    |> IO.iodata_to_binary()
    |> String.trim()
    |> then(fn str ->
      # If there are multiple lines, prefix with an empty line
      # to ensure the string is displayed correctly.
      if String.contains?(str, "\n") do
        "\n" <> str
      else
        str
      end
    end)
  end

  def iodata?(term) when is_binary(term), do: true
  def iodata?(term) when is_integer(term) and term in 0..255, do: true
  def iodata?([]), do: true
  def iodata?([head | tail]), do: iodata?(head) and iodata_tail?(tail)
  def iodata?(_), do: false

  defp iodata_tail?(tail) when is_list(tail), do: iodata?(tail)
  defp iodata_tail?(tail) when is_binary(tail), do: true
  defp iodata_tail?(_), do: false
end

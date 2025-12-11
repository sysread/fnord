defmodule UI do
  @moduledoc """
  User interface functions for output, logging, and user interaction.

  ## Context Warnings for Interactive UI

  Interactive UI functions (`confirm/1`, `choose/2`, `prompt/1`) can cause deadlocks
  when called from certain contexts and must be wrapped appropriately.

  ### GenServer Callbacks
  Use `UI.Queue.run_from_genserver/1` to prevent deadlocks:

      def handle_call(:delete_item, _from, state) do
        confirmed = UI.Queue.run_from_genserver(fn ->
          UI.confirm("Delete this item?")
        end)
        # ...
      end

  ### Services.Globals.Spawn.async and Spawned Processes
  Use `UI.Queue.run_from_task/1` when tasks need to participate in an existing UI interaction:

      task = Services.Globals.Spawn.async(fn ->
        UI.Queue.run_from_task(fn ->
          UI.confirm("Process this item?")
        end)
      end)

  ### Creating UI Components
  Use `UI.interact/1` to group multiple UI operations into a single atomic component:

      def confirm_with_details(item) do
        UI.interact(fn ->
          UI.info("Item details: \#{item.name}")
          UI.puts("Size: #\{item.size}, Modified: #\{item.date}")
          UI.confirm("Delete this item?")
        end)
      end

  Non-interactive functions (`info/2`, `warn/2`, `error/2`, `puts/1`, `say/1`) are safe
  to call directly from any context.

  ## Interactive vs Non-Interactive Functions

  **Interactive (require context wrappers in GenServer/Task contexts):**
  - `confirm/1` - waits for yes/no input
  - `choose/2` - waits for selection
  - `prompt/1` - waits for text input

  **Non-interactive (safe to call directly from any context):**
  - `info/2`, `warn/2`, `error/2`, `debug/2` - just output
  - `puts/1`, `say/1` - just output
  - `interact/1` - groups operations but doesn't itself interact
  """

  require Logger

  # ----------------------------------------------------------------------------
  # Messaging
  # ----------------------------------------------------------------------------
  @doc """
  Execute a function as a single interaction unit. All UI calls within the function
  (puts, log, choose, prompt, etc.) will be treated as part of this interaction
  and execute immediately without queuing.

  This is useful for composite TUI components that combine multiple UI elements.
  """
  def interact(fun) when is_function(fun, 0) do
    output_module().interact(fun)
  end

  def say(msg) do
    UI.flush()

    msg
    |> format_detail()
    |> output_module().puts()
  end

  def puts(msg) do
    output_module().puts(msg)
  end

  # ----------------------------------------------------------------------------
  # Feedback messages from the LLM
  # ----------------------------------------------------------------------------
  def feedback(:info, name, msg) do
    feedback(name, msg, :green_background, :green)
  end

  def feedback(:warn, name, msg) do
    feedback(name, msg, :yellow_background, :yellow)
  end

  def feedback(:error, name, msg) do
    feedback(name, msg, :red_background, :red)
  end

  def feedback(:debug, name, msg) do
    feedback(name, msg, :cyan_background, :cyan)
  end

  defp feedback(name, msg, label_codes, detail_codes) do
    msg =
      [
        label_codes,
        :bright,
        "༺  ",
        name,
        " ༻ ",
        :reset,
        ": ",
        :italic,
        detail_codes,
        msg,
        :reset
      ]
      |> IO.ANSI.format(colorize?())

    output_module().log(:info, msg)
  end

  # ----------------------------------------------------------------------------
  # Step reporting and logging
  # ----------------------------------------------------------------------------
  def report_from(nil, msg), do: info(msg)

  def report_from(name, msg) do
    IO.ANSI.format([:cyan, "⦑ #{name} ⦒ ", :reset, msg], colorize?())
    |> info()
  end

  def report_from(nil, msg, detail), do: info(msg, detail)

  def report_from(name, msg, detail) do
    output_module().log(
      :info,
      IO.ANSI.format(
        [
          :cyan,
          "⦑ #{name} ⦒ ",
          :reset,
          :green,
          msg,
          :reset,
          ": ",
          :light_black,
          clean_detail(detail),
          :reset
        ],
        colorize?()
      )
    )
  end

  def report_step(msg), do: info(msg)
  def report_step(msg, detail), do: info(msg, detail)

  def begin_step(msg) do
    IO.ANSI.format([:green, "➤ ", msg, :reset], colorize?())
    |> info()
  end

  def begin_step(msg, detail) do
    output_module().log(
      :info,
      IO.ANSI.format(
        [:green, "➤ ", msg, :reset, ": ", :cyan, clean_detail(detail), :reset],
        colorize?()
      )
    )
  end

  def end_step(msg) do
    IO.ANSI.format([:yellow, "✓ ", msg, :reset], colorize?())
    |> info()
  end

  def end_step(msg, detail) do
    output_module().log(
      :info,
      IO.ANSI.format(
        [:yellow, "✓ ", msg, :reset, ": ", :cyan, clean_detail(detail), :reset],
        colorize?()
      )
    )
  end

  def end_step_background(msg) do
    IO.ANSI.format([:light_black, "✓ ", msg, :reset], colorize?())
    |> info()
  end

  def end_step_background(msg, detail) do
    output_module().log(
      :info,
      IO.ANSI.format(
        [:light_black, "✓ ", msg, :reset, ": ", :light_black, clean_detail(detail), :reset],
        colorize?()
      )
    )
  end

  # Directly write to ensure visibility even if output is paused.
  def printf_debug(item) do
    Logger.debug(inspect(item, pretty: true))
    Logger.flush()
    item
  end

  def debug(msg) do
    msg = IO.ANSI.format([:green, msg, :reset], colorize?())
    output_module().log(:debug, msg)
  end

  def debug(msg, detail) do
    msg =
      IO.ANSI.format(
        [:green, msg, :reset, ": ", :cyan, clean_detail(detail), :reset],
        colorize?()
      )

    output_module().log(:debug, msg)
  end

  def info(msg) do
    output_module().log(:info, IO.ANSI.format([:green, msg, :reset], colorize?()))
  end

  def info(msg, detail) do
    output_module().log(
      :info,
      IO.ANSI.format(
        [:green, msg || "", :reset, ": ", :cyan, clean_detail(detail), :reset],
        colorize?()
      )
    )
  end

  def warn(msg) do
    output_module().log(:warning, IO.ANSI.format([:yellow, msg, :reset], colorize?()))
  end

  def warn(msg, detail) do
    output_module().log(
      :warning,
      IO.ANSI.format(
        [:yellow, msg, :reset, ": ", :cyan, clean_detail(detail), :reset],
        colorize?()
      )
    )
  end

  def error(msg) do
    output_module().log(:error, IO.ANSI.format([:red, msg, :reset], colorize?()))
  end

  def error(msg, detail) do
    output_module().log(
      :error,
      IO.ANSI.format([:red, msg, :reset, ": ", :cyan, clean_detail(detail), :reset], colorize?())
    )
  end

  # Directly write to ensure visibility even if output is paused.
  @spec fatal(binary) :: no_return()
  def fatal(msg) do
    Logger.error(IO.ANSI.format([:red, msg, :reset], colorize?()))
    Logger.flush()
    System.halt(1)
  end

  # Directly write to ensure visibility even if output is paused.
  @spec fatal(binary, binary) :: no_return()
  def fatal(msg, detail) do
    Logger.error(
      IO.ANSI.format([:red, msg, :reset, ": ", :cyan, clean_detail(detail), :reset], colorize?())
    )

    Logger.flush()
    System.halt(1)
  end

  # Directly write to stderr to ensure visibility even if output is paused.
  @spec warning_banner(binary) :: :ok
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

  @spec log_usage(AI.Model.t(), non_neg_integer | map) :: :ok
  def log_usage(model, usage) when is_integer(usage) do
    safe_usage = max(usage, 0)
    safe_context = max(model.context, 1)
    percentage = Float.round(safe_usage / safe_context * 100, 2)
    str_usage = Util.format_number(safe_usage)
    str_context = Util.format_number(safe_context)
    info("Context window usage", "#{percentage}% (#{str_usage} / #{str_context} tokens)")
  end

  def log_usage(model, %{"total_tokens" => total_tokens} = _usage) do
    log_usage(model, total_tokens)
  end

  def log_usage(model, %{total_tokens: total_tokens} = _usage) do
    log_usage(model, total_tokens)
  end

  @spec italicize(binary) :: iodata
  def italicize(text) do
    IO.ANSI.format([:italic, text, :reset], colorize?())
  end

  # ----------------------------------------------------------------------------
  # TUI/Animated elements
  # ----------------------------------------------------------------------------
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

  # ----------------------------------------------------------------------------
  # Interactive prompts
  # ----------------------------------------------------------------------------
  def choose(label, options, timeout_ms, default) do
    if UI.is_tty?() && !UI.quiet?() do
      output_module().choose(label, options, timeout_ms, default)
    else
      {:error, :no_tty}
    end
  end

  def choose(label, options) do
    if UI.is_tty?() && !UI.quiet?() do
      output_module().choose(label, options)
    else
      {:error, :no_tty}
    end
  end

  def prompt(prompt, owl_opts \\ []) do
    if UI.is_tty?() && !UI.quiet?() do
      owl_opts = Keyword.put(owl_opts, :label, prompt)

      output_module().prompt(prompt, owl_opts)
    else
      {:error, :no_tty}
    end
  end

  @spec confirm(binary) :: boolean
  def confirm(msg), do: confirm(msg, false)

  @spec confirm(binary, boolean) :: boolean
  def confirm(msg, default) do
    output_module().confirm(msg, default)
  end

  def newline do
    unless UI.quiet?() do
      output_module().newline()
    end
  end

  def box(contents, opts) do
    unless UI.quiet?() do
      output_module().newline()
      output_module().box(contents, opts)
    end
  end

  # ----------------------------------------------------------------------------
  # Helper functions
  # ----------------------------------------------------------------------------
  def flush, do: output_module().flush()

  defp output_module do
    Services.Globals.get_env(:fnord, :ui_output, UI.Output.Production)
  end

  def quiet?() do
    Services.Globals.get_env(:fnord, :quiet)
  end

  def is_tty? do
    :prim_tty.isatty(:stderr)
    |> case do
      true -> true
      _ -> false
    end
  end

  def colorize?, do: is_tty?() && !quiet?()

  defp format_detail(content) when is_binary(content) do
    content |> UI.Formatter.format_output()
  end

  defp format_detail(content) when is_list(content) do
    content |> IO.ANSI.format(colorize?())
  end

  defp format_detail(content) do
    # Fallback for other types - convert to string and treat as markdown
    content |> to_string() |> UI.Formatter.format_output()
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
      if String.contains?(str, "\n") do
        # If there are multiple lines, prefix with an empty line to ensure the
        # string is displayed correctly.
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

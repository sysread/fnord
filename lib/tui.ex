defmodule Tui do
  @moduledoc """
  Please don't judge me on how convoluted this is. Owl is so mediocre and
  elixir's logger is so complicated to configure dynamically in newer versions
  that I had to bolt together this monstrosity and now I'm watching helplessly
  as it lurches down to the village to wreak havoc on the townsfolk.

  I'm sorry, townsfolk. I'm so sorry.

  Anyway, this module is responsible for rendering the TUI. For interactive
  invocations, it uses Owl to render dynamic blocks with spinners and colorful
  status indicators.

  For non-interactive invocations, it uses the logger to output status messages
  and warnings to STDERR. You can prevent that by invoking `fnord` with:

  ```sh
  $ fnord ... 2>/dev/null
  ```

  You can force non-interactive output by piping to `tee`:

  ```sh
  $ fnord ... | tee
  ```
  """

  use GenServer

  require Logger

  @render_intvl 100
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
    "Cross-referencing the hallucination core"
  ]

  # -----------------------------------------------------------------------------
  # Client API
  # -----------------------------------------------------------------------------
  def start_link(opts) do
    Owl.LiveScreen.start_link(refresh_every: @render_intvl)
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def stop(pid, status \\ :normal) do
    GenServer.stop(pid, status)
  end

  def warn(msg, detail \\ nil) do
    GenServer.call(__MODULE__, {:warn, msg, detail})
  end

  def add_status(msg, detail \\ nil) do
    GenServer.call(__MODULE__, {:add_status, msg, detail})
  end

  def update_status(id, msg, detail \\ nil) do
    GenServer.cast(__MODULE__, {:update_status, id, msg, detail})
  end

  def add_step() do
    GenServer.call(__MODULE__, {:add_step})
  end

  def add_step(msg, detail \\ nil) do
    GenServer.call(__MODULE__, {:add_step, msg, detail})
  end

  def update_step(id, msg, detail \\ nil) do
    GenServer.cast(__MODULE__, {:update_step, id, msg, detail})
  end

  def finish_step(id, outcome) do
    GenServer.cast(__MODULE__, {:finish_step, id, outcome})
  end

  def finish_step(id, outcome, msg, detail \\ nil) do
    GenServer.cast(__MODULE__, {:finish_step, id, outcome, msg, detail})
  end

  # -----------------------------------------------------------------------------
  # Server callbacks
  # -----------------------------------------------------------------------------
  def init(opts) do
    state = %{
      opts: opts,
      id_counter: 0,
      statuses: %{},
      progress_char: "⠋",
      progress_color: :magenta,
      tty?: true,
      render_proc: nil
    }

    if opts[:quiet] do
      configure_logger()
      state = %{state | tty?: false}
      {:ok, state}
    else
      {:ok, render_proc} = Task.start_link(&render_interval/0)
      state = %{state | render_proc: render_proc}
      Owl.LiveScreen.add_block(:ask, state: status_box(state))
      {:ok, state}
    end
  end

  def terminate(_reason, %{tty?: false} = state) do
    state.statuses
    |> Enum.each(fn
      {id, {_msg, _detail, :processing}} -> log_msg(state, id)
      {id, {_msg, _detail, :status}} -> log_msg(state, id)
      _ -> nil
    end)

    :ok
  end

  def terminate(_reason, %{tty?: true} = state) do
    completed =
      state.statuses
      |> Enum.map(fn
        {id, {msg, detail, :processing}} -> {id, {msg, detail, :ok}}
        {id, {msg, detail, :status}} -> {id, {msg, detail, :status}}
        {id, {msg, detail, outcome}} -> {id, {msg, detail, outcome}}
      end)

    %{state | statuses: Map.new(completed)}
    |> render()

    Owl.LiveScreen.await_render()
    Owl.LiveScreen.flush()

    :ok
  end

  # -----------------------------------------------------------------------------
  # Warnings
  #   - tty?: true  -> owl
  #   - tty?: false -> logger
  # -----------------------------------------------------------------------------
  def handle_call({:warn, msg, detail}, _from, state) do
    {id, state} = next_id(state)
    state = %{state | statuses: Map.put(state.statuses, id, {msg, detail, :warn})}
    log_msg(state, id)
    {:reply, id, state}
  end

  # -----------------------------------------------------------------------------
  # Add status
  #  - tty?: true  -> owl
  #  - tty?: false -> logger, but only when the tui is shut down; just update
  #                   the record
  # -----------------------------------------------------------------------------
  def handle_call({:add_status, msg, detail}, _from, %{tty?: true} = state) do
    {id, state} = next_id(state)
    state = %{state | statuses: Map.put(state.statuses, id, {msg, detail, :status})}
    log_msg(state, id)
    {:reply, id, state}
  end

  def handle_call({:add_status, msg, detail}, _from, state) do
    {id, state} = next_id(state)
    state = %{state | statuses: Map.put(state.statuses, id, {msg, detail, :status})}
    {:reply, id, state}
  end

  # -----------------------------------------------------------------------------
  # Add step
  # - tty?: true  -> owl
  # - tty?: false -> logger (if complete)
  # -----------------------------------------------------------------------------
  def handle_call({:add_step, msg, detail}, _from, state) do
    {id, state} = next_id(state)
    state = %{state | statuses: Map.put(state.statuses, id, {msg, detail, :processing})}
    log_msg(state, id)
    {:reply, id, state}
  end

  def handle_call({:add_step}, _from, state) do
    {id, state} = next_id(state)
    state = %{state | statuses: Map.put(state.statuses, id, {nil, nil, :processing})}
    start_bs_label_changer(id)
    log_msg(state, id)
    {:reply, id, state}
  end

  # -----------------------------------------------------------------------------
  # Update status
  # - tty?: true  -> owl
  # - tty?: false -> logger, but only when the tui is shut down; just update
  #                  the record
  # -----------------------------------------------------------------------------
  def handle_cast({:update_status, id, msg, detail}, %{tty?: true} = state) do
    state = %{state | statuses: Map.put(state.statuses, id, {msg, detail, :status})}
    log_msg(state, id)
    {:noreply, state}
  end

  def handle_cast({:update_status, id, msg, detail}, state) do
    state = %{state | statuses: Map.put(state.statuses, id, {msg, detail, :status})}
    {:noreply, state}
  end

  # -----------------------------------------------------------------------------
  # Update step
  # - tty?: true  -> owl
  # - tty?: false -> logger (if complete)
  # -----------------------------------------------------------------------------
  def handle_cast({:update_step, id, msg, detail}, state) do
    state = %{state | statuses: Map.put(state.statuses, id, {msg, detail, :processing})}
    log_msg(state, id)
    {:noreply, state}
  end

  # -----------------------------------------------------------------------------
  # Finish step
  # - tty?: true  -> owl
  # - tty?: false -> logger
  # -----------------------------------------------------------------------------
  def handle_cast({:finish_step, id, outcome}, state) do
    {msg, detail, _old_outcome} = Map.get(state.statuses, id)
    state = %{state | statuses: Map.put(state.statuses, id, {msg, detail, outcome})}
    log_msg(state, id)
    {:noreply, state}
  end

  def handle_cast({:finish_step, id, outcome, msg, detail}, state) do
    state = %{state | statuses: Map.put(state.statuses, id, {msg, detail, outcome})}
    log_msg(state, id)
    {:noreply, state}
  end

  # -----------------------------------------------------------------------------
  # Render
  # -----------------------------------------------------------------------------
  def handle_cast(:render, nil), do: {:noreply, nil}
  def handle_cast(:render, state), do: {:noreply, render(state)}

  # -----------------------------------------------------------------------------
  # Internal functions
  # -----------------------------------------------------------------------------
  defp next_id(state) do
    id = state.id_counter
    {id, %{state | id_counter: state.id_counter + 1}}
  end

  def configure_logger do
    {:ok, handler_config} = :logger.get_handler_config(:default)
    updated_config = Map.update!(handler_config, :config, &Map.put(&1, :type, :standard_error))

    :ok = :logger.remove_handler(:default)
    :ok = :logger.add_handler(:default, :logger_std_h, updated_config)

    :ok =
      :logger.update_formatter_config(
        :default,
        :template,
        ["[", :level, "] ", :message, "\n"]
      )
  end

  defp log_msg(%{tty?: true}, _id) do
    :ok
  end

  defp log_msg(%{tty?: false} = state, id) do
    {msg, detail, outcome} = Map.get(state.statuses, id)

    if outcome != :processing do
      line =
        if is_nil(detail) do
          "#{msg}"
        else
          "#{msg}: #{detail}"
        end

      glyph = outcome_glyph(state, outcome)
      line = "#{glyph} #{line}"

      case outcome do
        :ok -> Logger.info(line)
        :warn -> Logger.warning(line)
        :error -> Logger.error(line)
        :status -> Logger.info(line)
      end
    end
  end

  defp render_interval() do
    GenServer.cast(__MODULE__, :render)
    Process.send_after(self(), :tick, @render_intvl)

    receive do
      :tick -> render_interval()
    end
  end

  defp render(state) do
    state = %{
      state
      | progress_char: next_progress_char(state.progress_char),
        progress_color: next_progress_color(state.progress_color)
    }

    Owl.LiveScreen.update(:ask, status_box(state))
    state
  end

  defp status_box(state) do
    cols = Owl.IO.columns()
    rows = Owl.IO.rows() - 2

    state
    |> status()
    |> Owl.Box.new(
      min_height: 1,
      min_width: cols,
      max_height: rows,
      max_width: cols,
      horizontal_align: :left,
      vertical_align: :top,
      truncate_lines: true,
      border_style: :none
    )
  end

  defp status(state) do
    state.statuses
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn id ->
      {msg, detail, outcome} = Map.get(state.statuses, id)
      format_msg(state, msg, detail, outcome)
    end)
    |> Enum.join("\n")
  end

  defp format_msg(state, msg, detail, outcome) do
    glyph = outcome_glyph(state, outcome)

    if is_nil(detail) do
      [glyph, "  ", Owl.Data.tag(msg, :cyan)]
    else
      detail =
        if String.contains?(detail, "\n") do
          detail |> String.split("\n") |> hd()
        else
          detail
        end

      [
        glyph,
        "  ",
        Owl.Data.tag(msg, :cyan),
        Owl.Data.tag(":", :cyan),
        " ",
        Owl.Data.tag(detail, :yellow)
      ]
    end
    |> Owl.Data.to_chardata()
  end

  defp outcome_glyph(%{tty?: true} = state, outcome) do
    case outcome do
      :processing -> Owl.Data.tag(state.progress_char, state.progress_color)
      :ok -> Owl.Data.tag("✔", :green)
      :error -> Owl.Data.tag("✖", :red)
      :warn -> Owl.Data.tag("︕", :yellow)
      :status -> Owl.Data.tag("ⓘ", :cyan)
      _ -> ""
    end
  end

  defp outcome_glyph(%{tty?: false}, outcome) do
    case outcome do
      :processing -> "*"
      :ok -> "✔"
      :warn -> "︕"
      :error -> "✖"
      :status -> "ⓘ"
    end
  end

  defp start_bs_label_changer(status_id) do
    Task.start(fn ->
      phrases = Enum.shuffle(@bullshit_sf_phrases)

      Enum.each(phrases, fn phrase ->
        update_step(status_id, phrase)
        Process.sleep(@bullshit_rotation_interval)
      end)

      # Restart the cycle after completing the list
      start_bs_label_changer(status_id)
    end)
  end

  # ⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠏
  defp next_progress_char("⠋"), do: "⠙"
  defp next_progress_char("⠙"), do: "⠹"
  defp next_progress_char("⠹"), do: "⠸"
  defp next_progress_char("⠸"), do: "⠼"
  defp next_progress_char("⠼"), do: "⠴"
  defp next_progress_char("⠴"), do: "⠦"
  defp next_progress_char("⠦"), do: "⠧"
  defp next_progress_char("⠧"), do: "⠏"
  defp next_progress_char("⠏"), do: "⠋"

  # :magenta :red :yellow :green :blue :cyan
  defp next_progress_color(:magenta), do: :red
  defp next_progress_color(:red), do: :yellow
  defp next_progress_color(:yellow), do: :green
  defp next_progress_color(:green), do: :blue
  defp next_progress_color(:blue), do: :cyan
  defp next_progress_color(:cyan), do: :magenta
end

defmodule Ask do
  use GenServer

  @render_intvl 100

  # -----------------------------------------------------------------------------
  # Client API
  # -----------------------------------------------------------------------------
  def run(opts) do
    {:ok, ask} = GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    Owl.LiveScreen.start_link(refresh_every: @render_intvl)

    agent = AI.Agent.Answers.new(AI.new(), opts)

    with {:ok, output} <- AI.Agent.Answers.perform(agent) do
      GenServer.stop(ask, :normal)
      Owl.IO.puts("")
      Owl.IO.puts(output)
    end
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
    {:ok, render_proc} = Task.start_link(&render_interval/0)

    state = %{
      opts: opts,
      id_counter: 0,
      statuses: %{},
      progress_char: "⠋",
      progress_color: :magenta,
      render_proc: render_proc
    }

    Owl.LiveScreen.add_block(:ask, state: status_box(state))

    {:ok, state}
  end

  def terminate(_reason, state) do
    completed =
      state.statuses
      |> Enum.map(fn
        {id, {msg, detail, :processing}} -> {id, {msg, detail, :ok}}
        {id, {msg, detail, outcome}} -> {id, {msg, detail, outcome}}
      end)

    %{state | statuses: Map.new(completed)}
    |> render()

    Owl.LiveScreen.await_render()
    Owl.LiveScreen.flush()

    :ok
  end

  def handle_call({:add_step, msg, detail}, _from, state) do
    {id, state} = next_id(state)
    state = %{state | statuses: Map.put(state.statuses, id, {msg, detail, :processing})}
    {:reply, id, state}
  end

  def handle_cast({:update_step, id, msg, detail}, state) do
    state = %{state | statuses: Map.put(state.statuses, id, {msg, detail, :processing})}
    {:noreply, state}
  end

  def handle_cast({:finish_step, id, outcome}, state) do
    {msg, detail, _old_outcome} = Map.get(state.statuses, id)
    state = %{state | statuses: Map.put(state.statuses, id, {msg, detail, outcome})}
    {:noreply, state}
  end

  def handle_cast({:finish_step, id, outcome, msg, detail}, state) do
    state = %{state | statuses: Map.put(state.statuses, id, {msg, detail, outcome})}
    {:noreply, state}
  end

  def handle_cast(:render, state) do
    {:noreply, render(state)}
  end

  # -----------------------------------------------------------------------------
  # Internal functions
  # -----------------------------------------------------------------------------
  defp next_id(state) do
    id = state.id_counter
    {id, %{state | id_counter: state.id_counter + 1}}
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
      word_wrap: :normal,
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
      [glyph, " ", Owl.Data.tag(msg, :cyan)]
    else
      [glyph, " ", Owl.Data.tag([msg, ":"], :cyan), " ", Owl.Data.tag(detail, :yellow)]
    end
    |> Owl.Data.to_chardata()
  end

  defp outcome_glyph(state, outcome) do
    case outcome do
      :processing -> Owl.Data.tag(state.progress_char, state.progress_color)
      :ok -> Owl.Data.tag("✔", :green)
      :error -> Owl.Data.tag("✖", :red)
    end
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

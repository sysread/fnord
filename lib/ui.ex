defmodule UI do
  use GenServer

  defstruct [
    :id_counter,
    :statuses,
    :max_tokens,
    :tokens
  ]

  # -----------------------------------------------------------------------------
  # Client API
  # -----------------------------------------------------------------------------
  def start_link() do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def add_status(msg, detail \\ nil) do
    GenServer.call(__MODULE__, {:add_status, msg, detail})
  end

  def complete_status(status_id, resolution) do
    GenServer.cast(__MODULE__, {:complete_status, status_id, resolution})
  end

  def complete_status(status_id, resolution, append) do
    GenServer.cast(__MODULE__, {:complete_status, status_id, resolution, append})
  end

  def add_token_usage(max_tokens) do
    GenServer.cast(__MODULE__, {:add_token_status, max_tokens})
  end

  def update_token_usage(tokens) do
    GenServer.cast(__MODULE__, {:update_token_status, tokens})
  end

  def puts(msg) do
    Owl.IO.puts(msg)
    Owl.LiveScreen.await_render()
  end

  # -----------------------------------------------------------------------------
  # Server callbacks
  # -----------------------------------------------------------------------------
  @impl true
  def init(_) do
    state = %__MODULE__{
      id_counter: 0,
      statuses: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:add_status, msg, detail}, _from, state) do
    {state, status_id} = do_add_status(state, msg, detail)
    {:reply, status_id, state}
  end

  @impl true
  def handle_cast({:complete_status, status_id, resolution}, state) do
    {:noreply, do_complete_status(state, status_id, resolution)}
  end

  @impl true
  def handle_cast({:complete_status, status_id, resolution, msg}, state) do
    {:noreply, do_complete_status(state, status_id, resolution, msg)}
  end

  @impl true
  def handle_cast({:add_token_status, max_tokens}, state) do
    {:noreply, do_add_token_status(state, max_tokens)}
  end

  @impl true
  def handle_cast({:update_token_status, tokens}, state) do
    {:noreply, do_update_token_status(state, tokens)}
  end

  # -----------------------------------------------------------------------------
  # Private functions
  # -----------------------------------------------------------------------------
  defp interactive?(), do: IO.ANSI.enabled?()

  defp do_add_status(state, msg, detail) do
    msg =
      if is_nil(detail) do
        msg
      else
        Owl.Data.tag(
          [msg, ": ", Owl.Data.tag(detail, :green)],
          :default_color
        )
        |> Owl.Data.to_chardata()
      end

    counter = state.id_counter + 1
    status_id = String.to_atom("status_#{counter}")
    statuses = Map.put(state.statuses, status_id, msg)

    if interactive?() do
      Owl.Spinner.start(id: status_id)
      Owl.Spinner.update_label(id: status_id, label: msg)
      Owl.LiveScreen.await_render()
    end

    {
      %__MODULE__{state | id_counter: counter, statuses: statuses},
      status_id
    }
  end

  defp do_complete_status(state, status_id, resolution, msg \\ nil) do
    status = Map.get(state.statuses, status_id)
    state = %{state | statuses: Map.delete(state.statuses, status_id)}

    msg =
      if is_nil(msg) do
        status
      else
        status <> ": " <> msg
      end

    if interactive?() do
      Owl.Spinner.stop(id: status_id, resolution: resolution, label: msg)
      Owl.LiveScreen.await_render()
    end

    state
  end

  defp do_add_token_status(state, max_tokens) do
    if interactive?() do
      box = token_usage_box(max_tokens, 0)
      Owl.LiveScreen.add_block(:tokens, state: box)
    end

    %__MODULE__{state | max_tokens: max_tokens, tokens: 0}
  end

  defp do_update_token_status(%{max_tokens: max_tokens} = state, tokens) do
    if interactive?() do
      box = token_usage_box(max_tokens, tokens)
      Owl.LiveScreen.update(:tokens, box)
    end

    %__MODULE__{state | tokens: tokens}
  end

  defp token_usage_box(max_tokens, tokens) do
    pct = tokens / max_tokens * 100.0
    pct_str = Number.Percentage.number_to_percentage(pct, precision: 2)

    pct_tag =
      cond do
        pct > 75.0 -> Owl.Data.tag(pct_str, :red)
        pct > 50.0 -> Owl.Data.tag(pct_str, :orange)
        pct > 25.0 -> Owl.Data.tag(pct_str, :yellow)
        true -> Owl.Data.tag(pct_str, :green)
      end

    tokens_str = Number.Delimit.number_to_delimited(tokens, precision: 0)
    max_tokens_str = Number.Delimit.number_to_delimited(max_tokens, precision: 0)

    content = Owl.Data.tag([pct_tag, " | #{tokens_str} / #{max_tokens_str}"], :default_color)

    Owl.Box.new(content,
      title: "Token usage",
      padding: 1,
      border_style: :solid_rounded,
      vertical_align: :middle,
      horizontal_align: :center,
      border_tag: :blue,
      min_width: 25
    )
  end
end

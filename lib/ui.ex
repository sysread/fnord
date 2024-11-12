defmodule UI do
  use GenServer

  require Logger

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
    else
      info(msg)
    end

    {
      %__MODULE__{state | id_counter: counter, statuses: statuses},
      status_id
    }
  end

  defp do_complete_status(state, status_id, resolution, msg \\ nil) do
    cond do
      interactive?() ->
        status = Map.get(state.statuses, status_id)

        output =
          case msg do
            nil -> status
            %Owl.Tag{} -> Owl.Data.tag([status, ": ", msg], :default_color)
            _ -> status <> ": " <> msg
          end

        Owl.Spinner.stop(id: status_id, resolution: resolution, label: output)
        Owl.LiveScreen.await_render()

      !is_nil(msg) ->
        info(msg)

      true ->
        :ok
    end

    %{state | statuses: Map.delete(state.statuses, status_id)}
  end

  defp do_add_token_status(state, max_tokens) do
    usage = token_usage(max_tokens, 0)

    if interactive?() do
      Owl.LiveScreen.add_block(:tokens, state: usage)
      Owl.LiveScreen.await_render()
    else
      info(usage)
    end

    %__MODULE__{state | max_tokens: max_tokens, tokens: 0}
  end

  defp do_update_token_status(%{max_tokens: max_tokens} = state, tokens) do
    usage = token_usage(max_tokens, tokens)

    if interactive?() do
      Owl.LiveScreen.update(:tokens, usage)
      Owl.LiveScreen.await_render()
    else
      info(usage)
    end

    %__MODULE__{state | tokens: tokens}
  end

  defp token_usage(max_tokens, tokens) do
    pct = tokens / max_tokens * 100.0
    pct_str = Number.Percentage.number_to_percentage(pct, precision: 2)

    tokens_str = Number.Delimit.number_to_delimited(tokens, precision: 0)
    max_tokens_str = Number.Delimit.number_to_delimited(max_tokens, precision: 0)

    if interactive?() do
      pct_tag =
        cond do
          pct > 66.0 -> Owl.Data.tag(pct_str, :red)
          pct > 33.0 -> Owl.Data.tag(pct_str, :yellow)
          true -> Owl.Data.tag(pct_str, :green)
        end

      content = Owl.Data.tag([pct_tag, " | #{tokens_str} / #{max_tokens_str}"], :default_color)

      Owl.Box.new(content,
        title: "Token usage",
        padding_x: 1,
        border_style: :solid_rounded,
        vertical_align: :middle,
        horizontal_align: :center,
        border_tag: :blue,
        min_width: 30
      )
    else
      "Token usage: #{pct_str} | #{tokens_str} / #{max_tokens_str}"
    end
  end

  defp info(msg) when is_binary(msg) do
    msg |> String.trim() |> Logger.info()
  end

  defp info(msg) do
    msg |> to_string() |> info()
  end
end

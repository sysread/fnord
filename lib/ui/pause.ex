defmodule UI.Pause do
  @moduledoc """
  Global pause gate for UI output. When paused, UI writes are buffered and only
  flushed on resume. Keeps prompts clean and avoids interleaving with tool output.
  """

  use Agent

  @type state :: %{paused?: boolean, buffer: [iodata]}

  @spec start_link(Keyword.t()) :: {:ok, pid} | {:error, term}
  def start_link(opts \\ []) do
    Agent.start_link(
      fn -> %{paused?: false, buffer: []} end,
      Keyword.merge([name: __MODULE__], opts)
    )
  end

  @spec pause() :: :ok
  def pause, do: Agent.update(__MODULE__, &%{&1 | paused?: true})

  @spec resume() :: :ok
  def resume do
    Agent.get_and_update(__MODULE__, fn %{buffer: buf} = s ->
      Enum.each(Enum.reverse(buf), &UI.__write_now__/1)
      {:ok, %{s | paused?: false, buffer: []}}
    end)

    :ok
  end

  @spec paused?() :: boolean()
  def paused?, do: Agent.get(__MODULE__, & &1.paused?)

  @spec write(iodata) :: :ok
  def write(iodata) do
    Agent.update(__MODULE__, fn
      %{paused?: true, buffer: buf} = s ->
        %{s | buffer: [iodata | buf]}

      s ->
        UI.__write_now__(iodata)
        s
    end)

    :ok
  end
end

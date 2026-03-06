defmodule UI.Tee do
  @moduledoc """
  Optional transcript writer for `--tee`. When started, every UI output
  (Logger messages, stdout puts, direct stderr writes) is mirrored to a
  plain-text file with ANSI escape codes stripped.

  When not running, `write/1` is a silent no-op, so callers never need to
  check whether tee mode is active.
  """

  use GenServer

  # ---------------------------------------------------------------------------
  # ANSI stripping
  # ---------------------------------------------------------------------------

  # Matches CSI sequences (e.g. \e[31m, \e[0;1;32m, \e[K) and OSC sequences
  # (e.g. \e]8;;url\e\\). Covers the full range of terminal escapes that Owl
  # and IO.ANSI produce.
  @ansi_re ~r/\x1b(?:\[[0-9;]*[a-zA-Z]|\][^\x1b]*\x1b\\|\][^\x07]*\x07)/

  @spec strip_ansi(Owl.Data.t() | iodata()) :: binary()
  def strip_ansi(data) do
    # Two kinds of data arrive here:
    # 1. Raw iodata from IO.ANSI.format (improper lists with ANSI escapes)
    # 2. Owl.Data.t() with Owl.Data.tag structs (from Owl.Box, etc.)
    #
    # Owl.Data.to_chardata/1 handles both: it strips Owl.Data.tag structs
    # and normalizes improper lists from IO.ANSI.format into valid iodata.
    # Raw ANSI escape sequences in strings pass through, so the regex strips
    # those from the flattened binary.
    data
    |> Owl.Data.to_chardata()
    |> IO.iodata_to_binary()
    |> String.replace(@ansi_re, "")
  end

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @spec start_link(Path.t()) :: GenServer.on_start()
  def start_link(path) do
    GenServer.start_link(__MODULE__, path, name: __MODULE__)
  end

  @doc """
  Write data to the tee file, stripping ANSI codes. No-op if tee is not
  running. Accepts iodata - it will be flattened to a binary before stripping.
  """
  @spec write(iodata()) :: :ok
  def write(data) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:write, data})
    end
  end

  @doc """
  Flush and close the tee file, then stop the GenServer.
  """
  @spec stop() :: :ok
  def stop do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(path) do
    case File.open(path, [:write, :utf8]) do
      {:ok, fd} -> {:ok, %{fd: fd}}
      {:error, reason} -> {:stop, {:file_open_failed, path, reason}}
    end
  end

  @impl true
  def handle_cast({:write, data}, %{fd: fd} = state) do
    clean = strip_ansi(data)
    IO.write(fd, clean)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{fd: fd}) do
    File.close(fd)
    :ok
  end
end

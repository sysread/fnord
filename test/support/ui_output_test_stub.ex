defmodule UI.Output.TestStub do
  @moduledoc """
  Test stub implementation of UI.Output that provides simple, capturable output.

  This implementation outputs text that can be captured by ExUnit.CaptureIO
  and provides predictable behavior for tests.
  """

  require Logger

  @behaviour UI.Output

  @impl UI.Output
  def puts(data) do
    IO.puts(data)
  end

  @impl UI.Output
  def log(level, data) do
    Logger.log(level, data)
  end

  @impl UI.Output
  def interact(fun) do
    # In tests, just execute the function directly
    fun.()
  end

  @impl UI.Output
  def choose(label, options) do
    IO.puts("#{label}")

    options
    |> Enum.with_index(1)
    |> Enum.each(fn {option, index} ->
      IO.puts("#{index}. #{option}")
    end)

    # Return first option for predictable test behavior
    List.first(options)
  end

  @impl UI.Output
  def choose(label, options, _timeout_ms, default) do
    IO.puts("#{label} (auto-selecting: #{default})")

    options
    |> Enum.with_index(1)
    |> Enum.each(fn {option, index} ->
      IO.puts("#{index}. #{option}")
    end)

    default
  end

  @impl UI.Output
  def prompt(prompt_text) do
    IO.puts("#{prompt_text}")
    "test_input"
  end

  @impl UI.Output
  def prompt(prompt_text, _opts) do
    prompt(prompt_text)
  end

  @impl UI.Output
  def confirm(msg) do
    confirm(msg, false)
  end

  @impl UI.Output
  def confirm(msg, default) do
    yes_no = if default, do: "(Y/n)", else: "(y/N)"
    IO.puts("#{msg} #{yes_no}")
    default
  end

  @impl UI.Output
  def newline do
    # Silent in tests - newline output not needed for test verification
    :ok
  end

  @impl UI.Output
  def box(_contents, _opts) do
    # Silent in tests - box output is not needed for test verification
    :ok
  end

  @impl UI.Output
  def flush do
    # No-op in tests
    :ok
  end
end

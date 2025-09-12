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
    IO.puts("")
  end

  @impl UI.Output
  def box(contents, opts) do
    title = Keyword.get(opts, :title, "")
    min_width = Keyword.get(opts, :min_width, 40)

    # Simple box representation for tests
    border = String.duplicate("-", max(min_width, String.length(title) + 4))

    if title != "" do
      IO.puts("┌#{border}┐")

      IO.puts(
        "│ #{title} #{String.duplicate(" ", max(0, String.length(border) - String.length(title) - 3))}│"
      )

      IO.puts("├#{border}┤")
    else
      IO.puts("┌#{border}┐")
    end

    # Output content with simple formatting
    content_str = to_string(contents)

    content_str
    |> String.split("\n")
    |> Enum.each(fn line ->
      padding = max(0, String.length(border) - String.length(line) - 2)
      IO.puts("│ #{line}#{String.duplicate(" ", padding)} │")
    end)

    IO.puts("└#{border}┘")
  end

  @impl UI.Output
  def flush do
    # No-op in tests
    :ok
  end
end

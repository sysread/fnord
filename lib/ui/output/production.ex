defmodule UI.Output.Production do
  @moduledoc """
  Production implementation of UI.Output that uses UI.Queue and Owl.IO.
  """

  require Logger

  @behaviour UI.Output

  @impl UI.Output
  def puts(data) do
    UI.Queue.puts(UI.Queue, :stdio, data)
  end

  @impl UI.Output
  def log(level, data) do
    UI.Queue.log(UI.Queue, level, data)
  end

  @impl UI.Output
  def interact(fun) do
    case UI.Queue.interact(UI.Queue, fun) do
      {:ok, result} ->
        result

      {:error, {%{} = exception, _stacktrace}} ->
        raise exception

      {:error, {:exit, reason}} ->
        exit(reason)

      {:error, {:throw, value}} ->
        throw(value)

      {:error, {kind, value}} ->
        # Fallback for other kinds
        raise RuntimeError, "#{kind}: #{inspect(value)}"
    end
  end

  @impl UI.Output
  def choose(label, options) do
    interact(fn ->
      with_notification_timeout(
        fn ->
          flush()
          Owl.IO.select(options, label: label)
        end,
        "Fnord is waiting for your selection: #{label}"
      )
    end)
  end

  @impl UI.Output
  def choose(label, options, timeout_ms, default) do
    interact(fn ->
      # Display the selection prompt
      task =
        Services.Globals.Spawn.async(fn ->
          flush()
          Owl.IO.select(options, label: label)
        end)

      # Phase A: wait for notification threshold
      case Task.yield(task, 60_000) do
        {:ok, selection} ->
          selection

        nil ->
          # Send OS notification and continue waiting
          Notifier.notify("Fnord", "Fnord is waiting for your selection: #{label}", [])

          case Task.yield(task, timeout_ms) do
            {:ok, selection} ->
              Notifier.dismiss("Fnord")
              selection

            nil ->
              Task.shutdown(task, :brutal_kill)
              Notifier.dismiss("Fnord")

              UI.Queue.log(
                UI.Queue,
                :info,
                "Auto-selection after timeout: #{label} -> #{inspect(default)}"
              )

              # Note: would need UI.debug here, but that would create circular dependency
              default
          end
      end
    end)
  end

  @impl UI.Output
  def prompt(prompt_text) do
    prompt(prompt_text, [])
  end

  @impl UI.Output
  def prompt(prompt_text, owl_opts) do
    interact(fn ->
      owl_opts = Keyword.put(owl_opts, :label, prompt_text)

      with_notification_timeout(
        fn ->
          flush()
          Owl.IO.input(owl_opts)
        end,
        "Fnord is waiting for your input: #{String.slice(prompt_text, 0..50)}"
      )
    end)
  end

  @impl UI.Output
  def confirm(msg) do
    confirm(msg, false)
  end

  @impl UI.Output
  def confirm(msg, default) do
    has_default = is_boolean(default)

    cond do
      is_tty?() ->
        yes = if default == true, do: "Y", else: "y"
        no = if default == false, do: "N", else: "n"

        interact(fn ->
          with_notification_timeout(
            fn ->
              flush()
              IO.write(:stderr, UI.Formatter.format_output("#{msg} (#{yes}/#{no}) "))

              case IO.gets("") do
                "y\n" -> true
                "Y\n" -> true
                _ -> default
              end
            end,
            "Fnord is waiting for your response to: #{msg}"
          )
        end)

      has_default ->
        default

      true ->
        Logger.warning(
          "Confirmation requested without default, but session is not connected to a TTY."
        )

        false
    end
  end

  @impl UI.Output
  def newline do
    puts("")
  end

  @impl UI.Output
  def box(contents, opts) do
    contents
    |> Owl.Box.new(opts)
    |> puts()
  end

  @impl UI.Output
  def flush do
    Logger.flush()
  end

  # Private helper functions
  defp with_notification_timeout(func, notification_message) do
    with_notification_timeout(func, notification_message, 60_000)
  end

  defp with_notification_timeout(func, notification_message, timeout_ms) do
    # Start a task to execute the function with UI.Queue context preserved
    task =
      Services.Globals.Spawn.async(fn ->
        UI.Queue.run_from_task(func)
      end)

    # Start a timer for the notification
    timer_ref =
      Process.send_after(self(), {:notification_timeout, notification_message}, timeout_ms)

    # Wait for the task to complete while handling timeout messages
    result = wait_for_task_with_timeout(task, timer_ref)

    # Clean up: cancel timer if still active
    Process.cancel_timer(timer_ref)

    result
  end

  defp wait_for_task_with_timeout(task, timer_ref) do
    wait_for_task_with_timeout(task, timer_ref, false)
  end

  defp wait_for_task_with_timeout(task, timer_ref, notification_sent?) do
    receive do
      {:notification_timeout, message} ->
        # Send notification but continue waiting for the task
        Notifier.notify("Fnord", message, [])
        wait_for_task_with_timeout(task, timer_ref, true)
    after
      100 ->
        # Check if task completed
        case Task.yield(task, 0) do
          {:ok, result} ->
            # If we sent a notification, try to dismiss it
            if notification_sent? do
              Notifier.dismiss("Fnord")
            end

            result

          nil ->
            # Keep waiting
            wait_for_task_with_timeout(task, timer_ref, notification_sent?)
        end
    end
  end

  defp is_tty? do
    :prim_tty.isatty(:stderr)
    |> case do
      true -> true
      _ -> false
    end
  end
end

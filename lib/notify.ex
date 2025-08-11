defmodule Notifier do
  @moduledoc """
  A simple notification module that works on MacOS and Linux.
  It uses `terminal-notifier` on MacOS and `notify-send` or `dunstify` on Linux.
  If neither is available, it falls back to printing a message to STDERR.
  """

  @spec notify(String.t(), String.t(), keyword) :: :ok | {:error, term}
  def notify(title, body, opts \\ []) do
    case :os.type() do
      {:unix, :darwin} -> mac_notify(title, body, opts)
      {:unix, :linux} -> linux_notify(title, body, opts)
      _ -> fallback_beep(title, body, opts)
    end
  end

  @doc """
  Attempts to dismiss/clear notifications for the given group.
  Only works on systems that support notification dismissal.
  """
  @spec dismiss(String.t()) :: :ok | {:error, term}
  def dismiss(group \\ "fnord") do
    case :os.type() do
      {:unix, :darwin} -> mac_dismiss(group)
      {:unix, :linux} -> linux_dismiss(group)
      # No-op for unsupported systems
      _ -> :ok
    end
  end

  # ----------------------------------------------------------------------------
  # MacOS
  # ----------------------------------------------------------------------------
  defp mac_notify(title, body, opts) do
    subtitle = Keyword.get(opts, :subtitle)
    group = Keyword.get(opts, :group, "fnord")
    open_url = Keyword.get(opts, :open, nil)

    cond do
      exe?("terminal-notifier") ->
        args =
          ["-title", title, "-message", body, "-group", group] ++
            if(subtitle, do: ["-subtitle", subtitle], else: []) ++
            if open_url, do: ["-open", open_url], else: []

        run("terminal-notifier", args)

      exe?("osascript") ->
        # osascript is built-in. Keep it simple for reliability.
        script =
          ~s(display notification #{applestr(body)} with title #{applestr(title)} ) <>
            if subtitle, do: ~s(subtitle #{applestr(subtitle)} ), else: ""

        run("osascript", ["-e", script])

      true ->
        fallback_beep(title, body, opts)
    end
  end

  defp applestr(s) do
    ~s(") <> String.replace(s, ~s("), ~s(\\")) <> ~s(")
  end

  defp mac_dismiss(group) do
    cond do
      exe?("terminal-notifier") ->
        # Remove all notifications for the group
        run("terminal-notifier", ["-remove", group])

      true ->
        # osascript doesn't support programmatic dismissal
        :ok
    end
  end

  # ----------------------------------------------------------------------------
  # Linux
  # ----------------------------------------------------------------------------
  defp linux_notify(title, body, opts) do
    # Don't try GUI if there's no session bus / display
    if gui_env?() do
      urgency = Keyword.get(opts, :urgency, "critical")
      timeout_ms = Keyword.get(opts, :timeout_ms, 10000)

      cond do
        exe?("notify-send") ->
          args = ["--urgency=#{urgency}", "--expire-time=#{timeout_ms}", title, body]
          run("notify-send", args)

        exe?("dunstify") ->
          args = ["-u", urgency, "-t", Integer.to_string(timeout_ms), title, body]
          run("dunstify", args)

        true ->
          fallback_beep(title, body, opts)
      end
    else
      fallback_beep(title, body, opts)
    end
  end

  defp gui_env?() do
    (System.get_env("WAYLAND_DISPLAY") || "") != "" ||
      (System.get_env("DISPLAY") || "") != ""
  end

  defp linux_dismiss(_group) do
    # Most Linux notification systems don't support easy programmatic dismissal
    # without tracking notification IDs, which would require significant changes
    :ok
  end

  # ----------------------------------------------------------------------------
  # Fallback
  # ----------------------------------------------------------------------------
  defp fallback_beep(_title, _body, _opts) do
    # I don't generally enable the terminal bell, but I guess it's better than
    # nothing.
    IO.puts(:stderr, "\a")
    :ok
  end

  # ----------------------------------------------------------------------------
  # Util
  # ----------------------------------------------------------------------------
  defp exe?(name), do: System.find_executable(name) != nil

  defp run(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {cmd, code, out}}
    end
  end
end

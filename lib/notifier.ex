defmodule Notifier do
  @moduledoc """
  A simple notification module that works on MacOS and Linux.

  On macOS it uses AppleScript (`osascript`); on Linux it uses `notify-send` or
  `dunstify`.

  If neither is available, it falls back to printing a bell to STDERR.
  """

  @type platform :: :mac | :linux | :other

  @spec notify(String.t(), String.t(), keyword) :: :ok | {:error, term}
  def notify(title, body, opts \\ []) do
    case platform(opts) do
      :mac -> mac_notify(title, body, opts)
      :linux -> linux_notify(title, body, opts)
      :other -> fallback_beep(title, body, opts)
    end
  end

  @doc """
  Attempts to dismiss/clear notifications for the given group.
  Only works on systems that support notification dismissal.
  """
  @spec dismiss(String.t(), keyword) :: :ok | {:error, term}
  def dismiss(group \\ "fnord", opts \\ []) do
    case platform(opts) do
      :mac -> mac_dismiss(group)
      :linux -> linux_dismiss(group)
      :other -> :ok
    end
  end

  # Decide platform (injectable for tests)
  @spec platform(keyword) :: platform
  defp platform(opts) do
    case Keyword.get(opts, :platform) do
      :mac ->
        :mac

      :linux ->
        :linux

      :other ->
        :other

      nil ->
        case :os.type() do
          {:unix, :darwin} -> :mac
          {:unix, :linux} -> :linux
          _ -> :other
        end
    end
  end

  # ----------------------------------------------------------------------------
  # MacOS (always AppleScript)
  # ----------------------------------------------------------------------------
  defp mac_notify(title, body, opts) do
    subtitle = Keyword.get(opts, :subtitle)
    title = applestr(title)
    body = applestr(body)

    subtitle_script =
      if subtitle do
        "subtitle " <> applestr(subtitle)
      else
        ""
      end

    run("osascript", [
      "-e",
      "display notification #{body} with title #{title} #{subtitle_script}"
    ])
  end

  # AppleScript notifications can't be programmatically dismissed.
  defp mac_dismiss(_group), do: :ok

  defp applestr(s), do: ~s(") <> String.replace(s, ~s("), ~s(\\")) <> ~s(")

  # ----------------------------------------------------------------------------
  # Linux
  # ----------------------------------------------------------------------------
  defp linux_notify(title, body, opts) do
    if gui_env?() do
      urgency = Keyword.get(opts, :urgency, "critical")
      timeout_ms = Keyword.get(opts, :timeout_ms, 10000)

      cond do
        exe?("notify-send") ->
          run("notify-send", ["--urgency=#{urgency}", "--expire-time=#{timeout_ms}", title, body])

        exe?("dunstify") ->
          run("dunstify", ["-u", urgency, "-t", Integer.to_string(timeout_ms), title, body])

        true ->
          fallback_beep(title, body, opts)
      end
    else
      fallback_beep(title, body, opts)
    end
  end

  defp gui_env?() do
    (Util.Env.get_env("WAYLAND_DISPLAY", "") || "") != "" ||
      (Util.Env.get_env("DISPLAY", "") || "") != ""
  end

  defp linux_dismiss(_group), do: :ok

  # ----------------------------------------------------------------------------
  # Fallback
  # ----------------------------------------------------------------------------
  defp fallback_beep(_title, _body, _opts) do
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

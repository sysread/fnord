defmodule UI.Formatter do
  @moduledoc """
  Formats output strings using an external command specified by the
  `FNORD_FORMATTER` environment variable. If unset or empty, returns the
  original string. On command failure or non-zero exit code, logs a warning and
  returns the original string.

  Note: We invoke the formatter via `shell -c`, which may be subject to shell
  injection if `FNORD_FORMATTER` contains malicious content. This CLI is
  intended for trusted environments, so this risk is accepted.
  """
  require Logger

  @timeout_ms 200

  @spec format_output(binary) :: binary
  def format_output(input) do
    if UI.quiet?() do
      input
    else
      case System.get_env("FNORD_FORMATTER") do
        nil ->
          input

        "" ->
          input

        formatter ->
          shell = System.get_env("SHELL") || "/bin/sh"

          with {:ok, tmpfile} <- Briefly.create(),
               :ok <- File.write(tmpfile, input) do
            Task.async(fn ->
              System.cmd(shell, ["-c", "cat #{tmpfile} | #{formatter}"], stderr_to_stdout: true)
            end)
            |> Task.await(@timeout_ms)
            |> case do
              {output, 0} ->
                output

              {_, exit_code} ->
                Logger.warning("Formatter command failed: #{formatter} (exit code: #{exit_code})")
                input

              nil ->
                Logger.warning("Formatter command failed: #{formatter}")
                input
            end
          end
      end
    end
  end
end

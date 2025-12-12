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

  # Allow a slightly more generous timeout; if it elapses, we fallback gracefully.
  @timeout_ms 1_000

  @spec format_output(binary) :: binary
  def format_output(input) do
    # Sanitize input to valid UTF-8 binary
    input =
      if(is_binary(input), do: input, else: to_string(input))
      |> String.replace_invalid("�")

    try do
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

            Util.Temp.with_tmp(input, fn tmpfile ->
              task =
                Services.Globals.Spawn.async(fn ->
                  System.cmd(shell, ["-c", "cat #{tmpfile} | #{formatter}"],
                    stderr_to_stdout: true
                  )
                end)

              case Task.yield(task, @timeout_ms) do
                {:ok, {output, 0}} ->
                  # Sanitize output to valid UTF-8 binary
                  output = String.replace_invalid(output, "�")
                  output

                {:ok, {_, exit_code}} ->
                  Logger.warning(
                    "Formatter command failed: #{formatter} (exit code: #{exit_code})"
                  )

                  input

                nil ->
                  # Timed out; make sure we don’t leak the task and fall back safely.
                  Task.shutdown(task, :brutal_kill)

                  Logger.warning(
                    "Formatter command timed out after #{@timeout_ms}ms: #{formatter}"
                  )

                  input
              end
            end)
        end
      end
    rescue
      _ -> input
    end
  end
end

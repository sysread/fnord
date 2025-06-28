defmodule UI.Formatter do
  @moduledoc """
  Formats output strings using an external command specified by the
  `FNORD_FORMATTER` environment variable. If unset or empty, returns the
  original string. On command failure or non-zero exit code, logs a warning
  and returns the original string.

  Note: We invoke the formatter via `shell -c`, which may be subject to shell
  injection if `FNORD_FORMATTER` contains malicious content. This CLI is
  intended for trusted environments, so this risk is accepted.
  """

  @spec format_output(String.t()) :: String.t()
  def format_output(input) when is_binary(input) do
    case System.get_env("FNORD_FORMATTER") do
      nil ->
        input

      "" ->
        input

      formatter ->
        shell = System.get_env("SHELL") || "/bin/sh"
        tmpfile = nil

        try do
          {:ok, tmpfile} = Briefly.create()
          :ok = File.write(tmpfile, input)

          cmd = "cat #{tmpfile} | #{formatter}"
          {output, exit_code} =
            System.cmd(shell, ["-c", cmd], stderr_to_stdout: true)

          if exit_code == 0 do
            output
          else
            UI.warn("Formatter command failed", "exit code #{exit_code}: #{formatter}")
            input
          end
        rescue
          error ->
            UI.warn("Formatter command execution failed: #{formatter}", inspect(error))

            input
        after
          case tmpfile do
            binary when is_binary(binary) ->
              if File.exists?(binary), do: File.rm(binary)
            _ ->
              :ok
          end
        end
    end
  end
end
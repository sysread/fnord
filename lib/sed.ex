defmodule Sed do
  @moduledoc """
  Cross-platform helper to run `sed` with in-place edits supporting line ranges
  and flags.
  """

  @spec run(binary, %{required(String.t()) => any}) :: :ok | {:error, binary}
  def run(file, %{"pattern" => pattern, "replacement" => replacement} = edit) do
    line_start = Map.get(edit, "line_start", nil)
    line_end = Map.get(edit, "line_end", nil)
    flags = Map.get(edit, "flags", "")

    range = build_range(line_start, line_end)
    script = "#{range}s/#{pattern}/#{replacement}/#{flags}"
    args = sed_args(file, script)

    case System.cmd("sed", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {err, _} -> {:error, "sed failed: #{String.trim(err)}"}
    end
  end

  defp build_range(nil, nil), do: ""
  defp build_range(start_line, nil) when is_integer(start_line), do: "#{start_line},$"
  defp build_range(nil, end_line) when is_integer(end_line), do: "1,#{end_line}"

  defp build_range(start_line, end_line) when is_integer(start_line) and is_integer(end_line) do
    "#{start_line},#{end_line}"
  end

  defp sed_args(file, script) do
    case :os.type() do
      # BSD/macOS sed: `-i ''` as two args for no backup
      {:unix, :darwin} -> ["-E", "-i", "", script, file]
      # GNU sed (Linux): `-i` with no space for no backup
      _ -> ["-E", "-i", script, file]
    end
  end
end

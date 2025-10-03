defmodule Util.Duration do
  @moduledoc """
  Human-friendly duration formatting utilities.

  Modes:
  - :natural (default): "H hours, M minutes, S seconds" with proper pluralization.
  - :compact          : "H:MM:SS" / "M:SS" / "Ss" (reserved for future use).
  """

  @type mode :: :natural | :compact

  @spec format(non_neg_integer(), mode()) :: String.t()
  def format(seconds, mode \\ :natural) when is_integer(seconds) and seconds >= 0 do
    case mode do
      :natural -> format_natural(seconds)
      :compact -> format_compact(seconds)
    end
  end

  @spec format_natural(non_neg_integer()) :: String.t()
  defp format_natural(seconds) do
    h = div(seconds, 3600)
    m = div(rem(seconds, 3600), 60)
    s = rem(seconds, 60)

    parts =
      [{h, "hour"}, {m, "minute"}, {s, "second"}]
      |> Enum.filter(fn {count, _unit} -> count > 0 end)
      |> Enum.map(fn {count, unit} -> pluralize(count, unit) end)

    if parts == [] do
      pluralize(0, "second")
    else
      Enum.join(parts, ", ")
    end
  end

  @spec format_compact(non_neg_integer()) :: String.t()
  defp format_compact(seconds) do
    h = div(seconds, 3600)
    m = div(rem(seconds, 3600), 60)
    s = rem(seconds, 60)

    cond do
      h > 0 -> "#{h}:#{pad2(m)}:#{pad2(s)}"
      m > 0 -> "#{m}:#{pad2(s)}"
      true -> "#{s}s"
    end
  end

  defp pluralize(0, unit), do: "0 #{unit}s"
  defp pluralize(1, unit), do: "1 #{unit}"
  defp pluralize(n, unit), do: "#{n} #{unit}s"

  defp pad2(n) when is_integer(n), do: String.pad_leading(Integer.to_string(n), 2, "0")
end

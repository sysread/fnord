defmodule Memory.Presentation do
  @moduledoc """
  Helpers for presenting `%Memory{}` metadata to humans.

  This module is intentionally small and pure (no I/O) so it can be reused by:

  - `AI.Tools.Memory` (tool output)
  - `Cmd.Memory` (CLI output)
  - `AI.Agent.Coordinator` (auto-injected recall section)

  Timestamps are stored on `%Memory{}` as ISO8601 strings (`DateTime.to_iso8601/1`).
  """

  @type iso8601 :: binary()

  @doc """
  Parse an ISO8601 timestamp string into a `DateTime`.

  Returns `{:ok, dt}` or `:error`.
  """
  @spec parse_ts(nil | iso8601()) :: {:ok, DateTime.t()} | :error
  def parse_ts(nil), do: :error

  def parse_ts(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> :error
    end
  end

  @doc """
  Returns the age in whole days since `dt` relative to `now`.

  If `dt` is in the future, returns `0`.
  """
  @spec age_days(DateTime.t(), DateTime.t()) :: non_neg_integer()
  def age_days(%DateTime{} = dt, %DateTime{} = now) do
    seconds = DateTime.diff(now, dt, :second)
    days = div(max(seconds, 0), 86_400)
    days
  end

  @doc """
  Returns an "Age" line for a memory.

  Examples:

  - `"Age: unknown (missing timestamps)"`
  - `"Age: 312 days (updated 12 days ago)"`

  Notes:
  - Uses `updated_at` if present; otherwise uses `inserted_at`.
  - Uses `now` for deterministic testing.
  """
  @spec age_line(Memory.t(), DateTime.t()) :: binary()
  def age_line(%Memory{} = mem, %DateTime{} = now) do
    inserted_days = ts_days(mem.inserted_at, now)
    updated_days = ts_days(mem.updated_at, now)

    cond do
      inserted_days == :unknown and updated_days == :unknown ->
        "Age: unknown (missing timestamps)"

      inserted_days != :unknown and updated_days == :unknown ->
        "Age: #{inserted_days} days"

      inserted_days == :unknown and updated_days != :unknown ->
        "Age: #{updated_days} days (updated #{updated_days} days ago)"

      true ->
        "Age: #{inserted_days} days (updated #{updated_days} days ago)"
    end
  end

  @doc """
  Returns an optional warning line based on how long ago the memory was updated.

  - If `updated_at` is missing/unparseable, returns `nil`.
  - If `updated_days >= strong_days`, returns a strong warning.
  - Else if `updated_days >= mild_days`, returns a mild warning.
  - Else returns `nil`.

  This is intended as a gentle prompt to check for cobwebs.
  """
  @spec warning_line(Memory.t(), DateTime.t(), keyword()) :: binary() | nil
  def warning_line(%Memory{} = mem, %DateTime{} = now, opts \\ []) do
    mild_days = Keyword.get(opts, :mild_days, 180)
    strong_days = Keyword.get(opts, :strong_days, 365)

    case ts_days(mem.updated_at, now) do
      :unknown ->
        nil

      days when is_integer(days) and days >= strong_days ->
        "Warning: last updated #{days} days ago. Check for cobwebs and verify/update/forget if stale."

      days when is_integer(days) and days >= mild_days ->
        "Note: last updated #{days} days ago. Consider checking for cobwebs."

      _ ->
        nil
    end
  end

  defp ts_days(ts, now) do
    case parse_ts(ts) do
      {:ok, dt} -> age_days(dt, now)
      :error -> :unknown
    end
  end
end

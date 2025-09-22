defmodule Settings.Instrumentation do
  @moduledoc """
  Capture and guard the approvals section on every write.
  """
  require Logger

  @baseline_table :fnord_approvals_baseline
  @trace_table :fnord_approvals_traces

  @spec init_baseline(map) :: :ok
  def init_baseline(data) do
    initial = Map.get(data, "approvals", %{})

    # Ensure baseline table exists
    if :ets.whereis(@baseline_table) == :undefined do
      try do
        :ets.new(@baseline_table, [:named_table, :public, read_concurrency: true])
      rescue
        ArgumentError -> :ok
      end
    end

    # Ensure trace table exists
    if :ets.whereis(@trace_table) == :undefined do
      try do
        :ets.new(@trace_table, [:named_table, :public, :bag, read_concurrency: true])
      rescue
        ArgumentError -> :ok
      end
    end

    # IMPORTANT: do NOT clear the baseline unconditionally. Seed it only if the
    # baseline is not already present.
    case :ets.lookup(@baseline_table, :baseline) do
      [] -> :ets.insert_new(@baseline_table, {:baseline, initial})
      _ -> :ok
    end

    :ok
  end

  @spec record_trace(atom, any, map, map) :: :ok
  def record_trace(op, key, before, after_value) do
    # Ensure ETS table exists before inserting the trace
    case :ets.whereis(@trace_table) do
      :undefined -> init_baseline(before)
      _ -> :ok
    end

    ts = System.system_time(:millisecond)

    # compute counts for before and after, ensuring after_counts has zeros for cleared keys
    before_counts = kind_counts(before)
    raw_after = kind_counts(after_value)

    after_counts =
      before_counts
      |> Enum.map(fn {k, _v} -> {k, Map.get(raw_after, k, 0)} end)
      |> Enum.into(%{})

    # build entry map for insertion
    entry = %{
      ts: ts,
      pid: self(),
      op: op,
      key: key,
      before_counts: before_counts,
      after_counts: after_counts,
      stack: trimmed_stack(20)
    }

    # Insert trace entry; ETS bag allows multiple entries per key
    :ets.insert(@trace_table, {:trace, ts, entry})
    :ok
  end

  @spec guard_or_heal(map, map, map) :: map
  def guard_or_heal(before, after_value, %{op: op, key: "approvals" = key}) do
    bc = kind_counts(before)
    ac = kind_counts(after_value)

    baseline =
      case :ets.lookup(@baseline_table, :baseline) do
        [{:baseline, b}] -> b
        _ -> %{}
      end

    if approvals_cleared?(before, after_value) and Enum.any?(bc, fn {_k, v} -> v > 0 end) do
      if debug?() do
        dump_debug(op, key, baseline, bc, ac)
        after_value
      else
        healed = merge_approvals(baseline, Map.get(after_value, "approvals", %{}))
        :ets.insert(@baseline_table, {:baseline, healed})
        Map.put(after_value, "approvals", healed)
      end
    else
      after_value
    end
  end

  def guard_or_heal(_, after_value, _), do: after_value

  @spec recent_traces(pos_integer) :: [map]
  def recent_traces(n) do
    :ets.lookup(@trace_table, :trace)
    |> Enum.map(fn {:trace, _ts, e} -> e end)
    |> Enum.sort_by(& &1.ts, :desc)
    |> Enum.take(n)
  end

  defp kind_counts(data) do
    case Map.get(data, "approvals") do
      ap when is_map(ap) ->
        ap
        |> Enum.into(%{}, fn {k, v} -> {k, if(is_list(v), do: length(v), else: 0)} end)

      _ ->
        %{}
    end
  end

  defp approvals_cleared?(_before, after_data) do
    Map.get(after_data, "approvals", %{})
    |> Enum.all?(fn {_k, v} -> v == [] end)
  end

  defp merge_approvals(baseline, curr) do
    Map.merge(baseline, curr, fn _k, o, n ->
      (o ++
         n)
      |> Enum.uniq()
      |> Enum.sort()
    end)
  end

  @doc """
  Returns true if the FNORD_DEBUG_SETTINGS environment variable is set to
  "1", "true", or "yes" (case-insensitive).
  """
  def debug?() do
    case System.get_env("FNORD_DEBUG_SETTINGS")
         |> to_string()
         |> String.downcase() do
      v when v in ["1", "true", "yes"] -> true
      _ -> false
    end
  end

  defp dump_debug(op, key, baseline, bc, ac) do
    # Log warning about cleared approvals in debug mode
    Logger.warning(
      "Settings FNORD_DEBUG_SETTINGS: approvals would have been cleared by #{op} on #{inspect(key)}.\n  baseline=#{inspect(baseline)} before=#{inspect(bc)} after=#{inspect(ac)}"
    )

    {:current_stacktrace, st} = Process.info(self(), :current_stacktrace)
    Logger.error("stack:\n#{Exception.format_stacktrace(st)}")
    Logger.error("traces:\n#{inspect(recent_traces(10), limit: :infinity)}")
  end

  defp trimmed_stack(limit) do
    {:current_stacktrace, st} = Process.info(self(), :current_stacktrace)

    st
    |> Enum.drop(2)
    |> Enum.take(limit)
  end
end

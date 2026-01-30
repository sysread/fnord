defmodule Services.BgIndexingControl do
  @moduledoc """
  Session-local (per BEAM node) control plane for pausing background indexing
  on a per-model basis.

  ## Why this exists

  Background indexing is a convenience feature. When OpenAI starts returning
  throttling responses (HTTP 429 with a recognized throttling code), we can
  disable background indexing for the affected model(s) to reduce load.

  This module is intentionally:

  - **model-agnostic**: any model string encountered can be tracked
  - **boolean-only**: models are either paused or not paused (no timers)
  - **session-local**: state is stored in `Services.Globals` and seeded idempotently

  ## State

  Stored in `Services.Globals` under the `:fnord` app:

  - `:bg_indexer_paused_models` => `%{model => true}`
  - `:bg_indexer_throttle_counts` => `%{model => consecutive_throttles}`
  - `:bg_indexer_throttle_threshold` => integer (default: 3)
  """

  @paused_key :bg_indexer_paused_models
  @counts_key :bg_indexer_throttle_counts
  @threshold_key :bg_indexer_throttle_threshold

  @default_threshold 3

  @spec ensure_init() :: :ok
  def ensure_init do
    ensure_default(@paused_key, %{})
    ensure_default(@counts_key, %{})
    ensure_default(@threshold_key, @default_threshold)
    :ok
  end

  defp ensure_default(key, default) do
    sentinel = :__bg_indexing_control_missing__

    case Services.Globals.get_env(:fnord, key, sentinel) do
      ^sentinel -> Services.Globals.put_env(:fnord, key, default)
      _ -> :ok
    end
  end

  @spec paused?(binary | nil) :: boolean
  def paused?(nil), do: false

  def paused?(model) when is_binary(model) do
    ensure_init()
    paused = Services.Globals.get_env(:fnord, @paused_key, %{})
    Map.get(paused, model, false) == true
  end

  @spec pause(binary | nil) :: :ok
  def pause(nil), do: :ok

  def pause(model) when is_binary(model) do
    ensure_init()
    paused = Services.Globals.get_env(:fnord, @paused_key, %{})
    Services.Globals.put_env(:fnord, @paused_key, Map.put(paused, model, true))
    :ok
  end

  @spec clear_pause(binary | nil) :: :ok
  def clear_pause(nil), do: :ok

  def clear_pause(model) when is_binary(model) do
    ensure_init()
    paused = Services.Globals.get_env(:fnord, @paused_key, %{})
    Services.Globals.put_env(:fnord, @paused_key, Map.delete(paused, model))
    :ok
  end

  @spec threshold() :: non_neg_integer
  def threshold do
    ensure_init()

    case Services.Globals.get_env(:fnord, @threshold_key, @default_threshold) do
      n when is_integer(n) and n >= 0 -> n
      _ -> @default_threshold
    end
  end

  @spec set_threshold(non_neg_integer) :: :ok
  def set_threshold(n) when is_integer(n) and n >= 0 do
    ensure_init()
    Services.Globals.put_env(:fnord, @threshold_key, n)
    :ok
  end

  @doc """
  Increment the consecutive throttling count for the model.

  If the count reaches the configured threshold, the model is paused.

  Returns `:ok` and ignores `nil` models.
  """
  @spec note_throttle(binary | nil) :: :ok
  def note_throttle(nil), do: :ok

  def note_throttle(model) when is_binary(model) do
    ensure_init()

    counts = Services.Globals.get_env(:fnord, @counts_key, %{})
    new_count = Map.get(counts, model, 0) + 1
    Services.Globals.put_env(:fnord, @counts_key, Map.put(counts, model, new_count))

    if new_count >= threshold() do
      pause(model)
    end

    :ok
  end

  @doc """
  Reset the consecutive throttling count for the model back to 0.

  Returns `:ok` and ignores `nil` models.
  """
  @spec note_success(binary | nil) :: :ok
  def note_success(nil), do: :ok

  def note_success(model) when is_binary(model) do
    ensure_init()

    counts = Services.Globals.get_env(:fnord, @counts_key, %{})
    Services.Globals.put_env(:fnord, @counts_key, Map.put(counts, model, 0))
    :ok
  end
end

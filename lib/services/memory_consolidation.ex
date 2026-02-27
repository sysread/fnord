defmodule Services.MemoryConsolidation do
  @moduledoc """
  Short-lived GenServer that coordinates memory consolidation within a single
  scope. Owns the precomputed similarity matrix and the set of remaining
  memories, serving as the single-threaded source of truth for which memories
  are still available.

  Workers call `checkout/1` to get a focus memory and its live candidates,
  then `complete/3` to report which memories were consumed. The pool filters
  candidates against `remaining` at checkout time, so workers always get a
  fresh view of what's available.

  Started per-scope by `Memory.Consolidator` and stopped when the
  consolidation pass is complete.
  """

  use GenServer

  # Cosine similarity floor. Candidates below this score are not sent to the
  # agent at all — they're too dissimilar to be worth evaluating.
  @similarity_floor 0.25

  # Maximum candidates to send per focus memory.
  @max_candidates 10

  # --------------------------------------------------------------------------
  # State
  # --------------------------------------------------------------------------

  defstruct [
    # MapSet of {scope, slug} keys for memories not yet checked out or consumed.
    :remaining,
    # MapSet of {scope, slug} keys currently checked out to workers.
    :in_flight,
    # %{ {scope, slug} => Memory.t() } for quick lookup by slug key.
    :memories,
    # %{ {scope, slug} => [{candidate_slug_key, score}] } — precomputed top
    # candidates per memory from the similarity matrix.
    :similarity,
    # Running report counters.
    :report
  ]

  # --------------------------------------------------------------------------
  # Public API
  # --------------------------------------------------------------------------

  @doc "Start a worker pool for the given list of memories."
  @spec start_link(list(Memory.t())) :: GenServer.on_start()
  def start_link(memories) do
    GenServer.start_link(__MODULE__, memories)
  end

  @doc """
  Check out a focus memory and its live candidates. Returns one of:
  - `{:ok, focus, candidates}` — work to do
  - `{:skip, focus}` — focus had no live candidates, already counted as kept
  - `:done` — no more memories to process
  """
  @spec checkout(GenServer.server()) ::
          {:ok, Memory.t(), list(map())} | {:skip, Memory.t()} | :done
  def checkout(server) do
    GenServer.call(server, :checkout, :infinity)
  end

  @doc """
  Report that a focus memory has been processed. `result` is one of:
  - `{:ok, eaten_slugs}` — focus kept, these candidates were consumed
  - `{:delete, eaten_slugs}` — focus itself was deleted, plus these candidates
  - `{:error, eaten_slugs}` — processing failed, candidates may still have been consumed
  """
  @spec complete(GenServer.server(), Memory.t(), {atom(), list()}) :: :ok
  def complete(server, focus, result) do
    GenServer.call(server, {:complete, focus, result}, :infinity)
  end

  @doc "Get the final consolidation report."
  @spec report(GenServer.server()) :: map()
  def report(server) do
    GenServer.call(server, :report)
  end

  # --------------------------------------------------------------------------
  # GenServer callbacks
  # --------------------------------------------------------------------------

  @impl GenServer
  def init(memories) do
    memory_map = build_memory_map(memories)
    similarity = build_similarity_matrix(memories, memory_map)
    remaining = memory_map |> Map.keys() |> MapSet.new()

    state = %__MODULE__{
      remaining: remaining,
      in_flight: MapSet.new(),
      memories: memory_map,
      similarity: similarity,
      report: %{merged: 0, deleted: 0, kept: 0, errors: 0}
    }

    {:ok, state}
  end

  @impl GenServer

  # Checkout: find the next remaining memory that isn't in-flight, filter its
  # candidates against the current remaining set, and hand it to the worker.
  def handle_call(:checkout, _from, state) do
    case pick_next(state) do
      nil ->
        {:reply, :done, state}

      {slug_key, focus} ->
        candidates = live_candidates(slug_key, state)

        state = %{state | in_flight: MapSet.put(state.in_flight, slug_key)}

        if candidates == [] do
          # No live candidates — mark as kept immediately, no LLM call needed.
          state = %{
            state
            | remaining: MapSet.delete(state.remaining, slug_key),
              in_flight: MapSet.delete(state.in_flight, slug_key),
              report: bump(state.report, :kept)
          }

          {:reply, {:skip, focus}, state}
        else
          {:reply, {:ok, focus, candidates}, state}
        end
    end
  end

  # Complete: worker finished processing a focus memory. Update remaining set
  # and report counters based on what happened.
  def handle_call({:complete, focus, result}, _from, state) do
    focus_key = slug_key(focus)

    {status, eaten_slugs} =
      case result do
        {:ok, eaten} -> {:kept, eaten}
        {:delete, eaten} -> {:deleted, eaten}
        {:error, eaten} -> {:error, eaten}
      end

    # Remove focus from in-flight and remaining.
    state = %{
      state
      | in_flight: MapSet.delete(state.in_flight, focus_key),
        remaining: MapSet.delete(state.remaining, focus_key)
    }

    # Remove eaten candidates from remaining.
    state =
      Enum.reduce(eaten_slugs, state, fn eaten_key, st ->
        %{
          st
          | remaining: MapSet.delete(st.remaining, eaten_key),
            in_flight: MapSet.delete(st.in_flight, eaten_key)
        }
      end)

    # Update report counters.
    report = state.report

    report =
      case status do
        :kept -> bump(report, :kept)
        :deleted -> bump(report, :deleted)
        :error -> bump(report, :errors)
      end

    # Each eaten slug counts as a merge — the focus absorbed it or it was
    # explicitly deleted. The worker already applied the specific action on
    # disk; from the coordinator's perspective they're all consumed.
    report =
      Enum.reduce(eaten_slugs, report, fn _, r -> bump(r, :merged) end)

    {:reply, :ok, %{state | report: report}}
  end

  def handle_call(:report, _from, state) do
    {:reply, state.report, state}
  end

  # --------------------------------------------------------------------------
  # Similarity matrix
  # --------------------------------------------------------------------------

  # Build a map of slug_key => Memory struct for O(1) lookup.
  defp build_memory_map(memories) do
    Map.new(memories, fn mem -> {slug_key(mem), mem} end)
  end

  # Precompute the similarity matrix: for each memory, find its top candidates
  # above the floor. This is O(n²) dot products but runs once at startup and
  # avoids repeated computation during the consolidation pass.
  defp build_similarity_matrix(memories, memory_map) do
    Map.new(memory_map, fn {key, mem} ->
      candidates =
        case mem.embeddings do
          nil ->
            []

          needle ->
            memories
            |> Enum.reject(fn m -> slug_key(m) == key or is_nil(m.embeddings) end)
            |> Enum.map(fn m ->
              score = AI.Util.cosine_similarity(needle, m.embeddings)
              {slug_key(m), score}
            end)
            |> Enum.filter(fn {_, score} -> score >= @similarity_floor end)
            |> Enum.sort_by(fn {_, score} -> score end, :desc)
            |> Enum.take(@max_candidates)
        end

      {key, candidates}
    end)
  end

  # --------------------------------------------------------------------------
  # Checkout helpers
  # --------------------------------------------------------------------------

  # Pick the next memory from remaining that isn't currently in-flight.
  defp pick_next(state) do
    state.remaining
    |> MapSet.difference(state.in_flight)
    |> Enum.at(0)
    |> case do
      nil -> nil
      key -> {key, Map.fetch!(state.memories, key)}
    end
  end

  # Filter a memory's precomputed candidates against what's still remaining
  # and not in-flight. Returns enriched candidate maps ready for the agent.
  defp live_candidates(focus_key, state) do
    state.similarity
    |> Map.get(focus_key, [])
    |> Enum.filter(fn {cand_key, _score} ->
      MapSet.member?(state.remaining, cand_key) and
        not MapSet.member?(state.in_flight, cand_key)
    end)
    |> Enum.map(fn {cand_key, score} ->
      mem = Map.fetch!(state.memories, cand_key)

      %{
        memory: mem,
        score: score,
        tier: Memory.Consolidator.tier_label(score)
      }
    end)
  end

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  defp slug_key(%Memory{scope: scope, slug: slug}) when is_binary(slug), do: {scope, slug}

  defp slug_key(%Memory{scope: scope, title: title}),
    do: {scope, Memory.title_to_slug(title)}

  defp bump(report, key), do: Map.update!(report, key, &(&1 + 1))
end

defmodule Services.SamskaraReactor do
  @moduledoc """
  Per-session reactor that listens for completed user turns, runs the cheap
  `AI.Agent.ReactionClassifier` on the hot path, and, when the classifier
  reports a significant reaction, spawns an async task to run the heavier
  `AI.Agent.SamskaraMinter`.

  Designed to never block the coordinator: all model work runs inside
  `Task.Supervisor` under `Services.TaskSupervisor`, and the GenServer only
  tracks in-flight tasks so they can be drained on shutdown.
  """

  use GenServer

  @significance_threshold 0.5

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------
  @spec start_link(keyword) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Notify the reactor that a user turn has just completed. `prev_assistant` is
  the assistant's most recent response, `user_message` is the user's reply.
  The reactor returns immediately; any minting happens asynchronously.
  """
  @spec observe_turn(pid | atom, map) :: :ok
  def observe_turn(server \\ __MODULE__, %{} = turn) do
    GenServer.cast(server, {:observe_turn, turn})
  end

  @doc """
  Testing helper: block until all in-flight mint tasks complete.
  """
  @spec drain(pid | atom, timeout) :: :ok
  def drain(server \\ __MODULE__, timeout \\ 30_000) do
    GenServer.call(server, :drain, timeout)
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------
  @impl true
  def init(_opts) do
    {:ok, %{tasks: %{}}}
  end

  @impl true
  def handle_cast({:observe_turn, turn}, state) do
    case maybe_start_mint(turn) do
      nil ->
        {:noreply, state}

      %Task{ref: ref} = task ->
        {:noreply, %{state | tasks: Map.put(state.tasks, ref, task)}}
    end
  end

  @impl true
  def handle_call(:drain, _from, %{tasks: tasks} = state) do
    tasks
    |> Map.values()
    |> Enum.each(fn %Task{} = task ->
      try do
        Task.await(task, 30_000)
      catch
        :exit, _ -> :ok
      end
    end)

    {:reply, :ok, %{state | tasks: %{}}}
  end

  @impl true
  def handle_info({ref, _result}, %{tasks: tasks} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | tasks: Map.delete(tasks, ref)}}
  end

  def handle_info({:DOWN, ref, _kind, _pid, _reason}, %{tasks: tasks} = state) do
    {:noreply, %{state | tasks: Map.delete(tasks, ref)}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------
  defp maybe_start_mint(turn) do
    cond do
      not enabled?() ->
        nil

      not valid_turn?(turn) ->
        nil

      true ->
        case Process.whereis(Services.TaskSupervisor) do
          nil ->
            nil

          _pid ->
            Task.Supervisor.async_nolink(Services.TaskSupervisor, fn ->
              run_mint_pipeline(turn)
            end)
        end
    end
  end

  @doc false
  def run_mint_pipeline(turn) do
    project = resolve_project(turn)

    with %Store.Project{} <- project,
         {:ok, {:mint, label, intensity}} <- classify(turn),
         true <- intensity >= @significance_threshold do
      mint(project, turn, label, intensity)
    else
      _ -> :skip
    end
  rescue
    e ->
      if Util.Env.looks_truthy?("FNORD_DEBUG_SAMSKARA") do
        UI.debug("samskara:reactor", "exception: #{Exception.message(e)}")
      end

      :error
  end

  defp classify(turn) do
    AI.Agent.ReactionClassifier
    |> AI.Agent.new(named?: false)
    |> AI.Agent.get_response(%{
      prev_assistant: turn.prev_assistant,
      user_message: turn.user_message
    })
  end

  defp mint(project, turn, label, intensity) do
    AI.Agent.SamskaraMinter
    |> AI.Agent.new(named?: false)
    |> AI.Agent.get_response(%{
      project: project,
      reaction: label,
      intensity: intensity,
      prev_assistant: turn.prev_assistant,
      user_message: turn.user_message,
      source_turn_ref: Map.get(turn, :source_turn_ref)
    })
  end

  defp valid_turn?(%{prev_assistant: p, user_message: u}) when is_binary(p) and is_binary(u) do
    p != "" and u != ""
  end

  defp valid_turn?(_), do: false

  defp enabled? do
    not Util.Env.looks_truthy?("FNORD_SAMSKARA_DISABLED")
  end

  defp resolve_project(%{project: %Store.Project{} = project}), do: project

  defp resolve_project(%{project: name}) when is_binary(name) do
    case Store.get_project(name) do
      {:ok, p} -> p
      _ -> nil
    end
  end

  defp resolve_project(_) do
    case Store.get_project() do
      {:ok, p} -> p
      _ -> nil
    end
  end

end

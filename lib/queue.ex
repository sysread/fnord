defmodule Queue do
  use GenServer

  @moduledoc """
  A module that implements a process pool using a GenServer.
  """

  # -----------------------------------------------------------------------------
  # Client API
  # -----------------------------------------------------------------------------
  @doc """
  Starts the Queue with the given callback function and maximum number of workers.
  """
  def start_link(max_workers, callback) do
    GenServer.start_link(__MODULE__, {callback, max_workers}, name: __MODULE__)
  end

  @doc """
  Adds a job to the queue and returns a Task.
  """
  def queue(args) do
    task =
      Task.async(fn ->
        receive do
          {:result, result} -> result
        end
      end)

    GenServer.cast(__MODULE__, {:queue_job, args, task.pid})
    task
  end

  @doc """
  Shuts down the queue, preventing new jobs from being added.
  """
  def shutdown do
    GenServer.cast(__MODULE__, :shutdown)
  end

  @doc """
  Waits until the queue is empty and all workers have exited.
  """
  def join do
    GenServer.call(__MODULE__, :join, :infinity)
  end

  @doc """
  Queues an Enum of jobs, executes them, and returns the results in order.
  """
  def map(enum) do
    tasks = Enum.map(enum, fn args -> queue(args) end)
    Enum.map(tasks, fn task -> Task.await(task) end)
  end

  # -----------------------------------------------------------------------------
  # Server Callbacks
  # -----------------------------------------------------------------------------
  def init({callback, max_workers}) do
    state = %{
      jobs: :queue.new(),
      max_workers: max_workers,
      callback: callback,
      workers: [],
      shutdown: false,
      waiting: []
    }

    state = start_workers(state)
    {:ok, state}
  end

  def handle_cast({:queue_job, args, task_pid}, state) do
    if state.shutdown do
      send(task_pid, {:result, {:error, :queue_shutdown}})
      {:noreply, state}
    else
      jobs = :queue.in({args, task_pid}, state.jobs)
      {:noreply, %{state | jobs: jobs}}
    end
  end

  def handle_cast(:shutdown, state) do
    {:noreply, %{state | shutdown: true}}
  end

  def handle_cast({:worker_exited, pid}, state) do
    workers = List.delete(state.workers, pid)
    state = %{state | workers: workers}
    check_if_done(state)
  end

  def handle_call({:request_job, _worker_pid}, _from, state) do
    if :queue.is_empty(state.jobs) do
      if state.shutdown do
        {:reply, :shutdown, state}
      else
        {:reply, :no_job, state}
      end
    else
      {{:value, {args, task_pid}}, jobs} = :queue.out(state.jobs)
      state = %{state | jobs: jobs}
      {:reply, {:job, {args, task_pid}}, state}
    end
  end

  def handle_call(:join, from, state) do
    if :queue.is_empty(state.jobs) and state.shutdown and length(state.workers) == 0 do
      {:reply, :ok, state}
    else
      waiting = [from | state.waiting]
      {:noreply, %{state | waiting: waiting}}
    end
  end

  # -----------------------------------------------------------------------------
  # Helper Functions
  # -----------------------------------------------------------------------------
  defp start_workers(state) do
    workers =
      Enum.map(1..state.max_workers, fn _ ->
        {:ok, pid} = Queue.Worker.start_link(self(), state.callback)
        pid
      end)

    %{state | workers: workers}
  end

  defp check_if_done(state) do
    if state.shutdown and :queue.is_empty(state.jobs) and length(state.workers) == 0 do
      Enum.each(state.waiting, fn from -> GenServer.reply(from, :ok) end)
      {:noreply, %{state | waiting: []}}
    else
      {:noreply, state}
    end
  end
end

defmodule Queue.Worker do
  @moduledoc false

  def start_link(queue_pid, callback) do
    pid = spawn_link(__MODULE__, :loop, [queue_pid, callback])
    {:ok, pid}
  end

  def loop(queue_pid, callback) do
    job = GenServer.call(queue_pid, {:request_job, self()})

    case job do
      {:job, {args, task_pid}} ->
        result = callback.(args)
        send(task_pid, {:result, result})
        loop(queue_pid, callback)

      :no_job ->
        :timer.sleep(100)
        loop(queue_pid, callback)

      :shutdown ->
        GenServer.cast(queue_pid, {:worker_exited, self()})
        :ok
    end
  end
end
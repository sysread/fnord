defmodule Queue do
  use GenServer

  defstruct [:size, :supervisor, :callback, :current_tasks, :queue, :closed, :awaiting_completion]

  # -----------------------------------------------------------------------------
  # Client API
  # -----------------------------------------------------------------------------
  def new(size, callback) do
    {:ok, supervisor} = Task.Supervisor.start_link(max_children: size)

    initial_state = %Queue{
      size: size,
      supervisor: supervisor,
      callback: callback,
      current_tasks: 0,
      queue: :queue.new(),
      closed: false,
      awaiting_completion: nil
    }

    GenServer.start_link(__MODULE__, initial_state)
  end

  # Queue a task
  def queue_task(pid, task) do
    GenServer.cast(pid, {:queue_task, task})
  end

  # Close the queue and wait for it to drain
  def close_and_wait(pid, timeout \\ :infinity) do
    GenServer.call(pid, :close_and_wait, timeout)
  end

  # -----------------------------------------------------------------------------
  # Server API (GenServer)
  # -----------------------------------------------------------------------------
  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_cast({:queue_task, _task}, %{closed: true} = state) do
    # If the queue is closed, we reject any new tasks
    {:noreply, state}
  end

  @impl true
  def handle_cast({:queue_task, task}, state) do
    # Add the task to the queue if the queue is not closed
    new_queue = :queue.in(task, state.queue)
    new_state = %{state | queue: new_queue}

    # Try to dispatch tasks if workers are available
    new_state = dispatch_tasks(new_state)

    # Return the correct tuple for GenServer
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:task_finished, state) do
    # Decrement the count of running tasks
    new_state = %{state | current_tasks: state.current_tasks - 1}

    # Dispatch more tasks if available
    {:noreply, dispatch_tasks(new_state)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Decrement the count of running tasks
    new_state = %{state | current_tasks: state.current_tasks - 1}

    # Check if we need to notify someone awaiting task completion
    if state.closed and new_state.current_tasks == 0 and :queue.is_empty(new_state.queue) do
      if state.awaiting_completion do
        GenServer.reply(state.awaiting_completion, :done)
      end
    end

    {:noreply, dispatch_tasks(new_state)}
  end

  # Handle closing the queue and waiting for it to drain
  @impl true
  def handle_call(:close_and_wait, from, state) do
    if :queue.is_empty(state.queue) and state.current_tasks == 0 do
      {:reply, :done, %{state | closed: true}}
    else
      # Mark the queue as closed and remember who's waiting
      new_state = %{state | closed: true, awaiting_completion: from}

      # Dispatch remaining tasks and return the updated state
      new_state = dispatch_tasks(new_state)

      # Correct return value for GenServer
      {:noreply, new_state}
    end
  end

  # -----------------------------------------------------------------------------
  # Private functions
  # -----------------------------------------------------------------------------
  defp dispatch_tasks(state) do
    if state.current_tasks < state.size and not :queue.is_empty(state.queue) do
      {{:value, task}, new_queue} = :queue.out(state.queue)

      # Increment the count of running tasks and update the queue
      new_state = %{state | current_tasks: state.current_tasks + 1, queue: new_queue}

      # Start the task asynchronously and monitor it
      {:ok, pid} =
        Task.Supervisor.start_child(state.supervisor, fn ->
          state.callback.(task)
        end)

      # Monitor the task to receive :DOWN messages
      Process.monitor(pid)

      # Recursively try to dispatch more tasks and return the updated state
      dispatch_tasks(new_state)
    else
      state
    end
  end
end

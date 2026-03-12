defmodule AI.Agent.Composite do
  @moduledoc """
  Behaviour and execution engine for composite agents - agents that orchestrate
  work across multiple completion turns, optionally with tool use, structured
  output, and sub-agent delegation.

  ## Steps as state

  A composite agent's work is defined as a dequeue of steps. Each step is either
  a **completion** (a turn in this agent's conversation) or a **delegation**
  (spawning a sub-agent). Steps can be grouped in a list for parallel execution.

  Example step queues:

      # Reviewer: fixed pipeline with parallel specialist fan-out
      [formulate, [pedantic, acceptance, state_flow], incorporate]

      # Coder planner: fixed sequential pipeline
      [research, visualize, plan]

      # Coder orchestrator: dynamic - validate can push tasks back
      [task_1, task_2, task_3, validate]

  ## Step types

  A `completion` step runs a prompt against this agent's conversation, accumulating
  the response into the message history:

      AI.Agent.Composite.completion(:research, "Investigate the code...",
        response_format: %{...}, keep_prompt?: false)

  A `delegate` step spawns a sub-agent. The sub-agent runs its own independent
  conversation; its response is injected into the parent's message history as a
  user message with a header identifying the source:

      AI.Agent.Composite.delegate(:pedantic, AI.Agent.Review.Pedantic,
        fn state -> %{prompt: ..., scope: state.request} end)

  ## Parallel execution

  When a step in the queue is a list, all steps in that list run concurrently.
  Results are collected and injected into the conversation in list order before
  the next sequential step begins.

  ## Lifecycle

  The execution engine calls implementation callbacks at each stage:

  1. `init/1` - Build the initial state and step queue.
  2. Pop the next item from the step queue.
  3. `on_step_start/2` - Pre-execution hook (logging, UI).
  4. Execute the step (completion or delegation).
  5. `on_step_complete/2` - Post-execution hook (parse response, update state).
  6. `get_next_steps/2` - Return steps to prepend to the queue, enabling
     dynamic control flow (retry, task generation, validation loops).
  7. Go to 2.
  """

  # ---------------------------------------------------------------------------
  # Step types
  # ---------------------------------------------------------------------------

  @type step_name :: atom

  @type completion_step :: %{
          type: :completion,
          name: step_name,
          prompt: binary,
          model: AI.Model.t() | nil,
          toolbox: AI.Tools.toolbox() | nil,
          response_format: map | nil,
          keep_prompt?: boolean
        }

  @type delegate_step :: %{
          type: :delegate,
          name: step_name,
          agent: module,
          args_builder: (t -> map)
        }

  @type step :: completion_step | delegate_step

  @type step_queue :: [step | [step]]

  # ---------------------------------------------------------------------------
  # State
  # ---------------------------------------------------------------------------

  defstruct [
    :agent,
    :model,
    :toolbox,
    :request,
    :response,
    :error,
    :messages,
    :internal,
    :steps
  ]

  @type t :: %__MODULE__{
          agent: AI.Agent.t(),
          model: AI.Model.t(),
          toolbox: AI.Tools.toolbox(),
          request: binary,
          response: binary | nil,
          error: any,
          messages: AI.Util.msg_list(),
          internal: map,
          steps: step_queue
        }

  # ---------------------------------------------------------------------------
  # Behaviour callbacks
  # ---------------------------------------------------------------------------

  @doc """
  Initialize the composite agent from the caller-provided args map (which
  includes `:agent` injected by `AI.Agent.get_response/2`). Must return a
  fully populated `%AI.Agent.Composite{}` with the initial step queue.
  """
  @callback init(args :: map) :: {:ok, t} | {:error, any}

  @doc """
  Called immediately before a step executes. Typically used for UI reporting
  (`UI.report_from/2`). Must return the (possibly modified) state.
  """
  @callback on_step_start(step :: step, state :: t) :: t

  @doc """
  Called after a step completes successfully. The step's response is in
  `state.response` and has been appended to `state.messages`. Use this to
  parse structured output and update `state.internal`.

  Must return the updated state.
  """
  @callback on_step_complete(step :: step, state :: t) :: t

  @doc """
  Called after `on_step_complete/2`. Returns a list of steps to prepend to the
  front of the queue. Return `[]` to continue with the existing queue.

  This is the primary mechanism for dynamic control flow:
  - Retry: return `[the_same_step]`
  - Task generation: return `[task_1, task_2, ..., validate]`
  - Conditional branching: inspect `state.internal` and return different steps

  For the reviewer, this always returns `[]` since the pipeline is fixed.
  For the coder, the plan step returns task steps, and the validate step can
  return more task steps on failure.
  """
  @callback get_next_steps(step :: step, state :: t) :: [step | [step]]

  @doc """
  Called when a step fails. `state.error` contains the error. Return one of:
  - `{:retry, state}` - re-execute the same step
  - `{:skip, state}` - clear the error and continue to the next step
  - `{:halt, state}` - stop execution with the error
  """
  @callback on_error(step :: step, error :: any, state :: t) ::
              {:retry, t} | {:skip, t} | {:halt, t}

  # ---------------------------------------------------------------------------
  # Step constructors
  # ---------------------------------------------------------------------------

  @doc """
  Creates a completion step - a turn in this agent's conversation.

  Options:
  - `:model` - override the agent's default model for this step
  - `:toolbox` - override the agent's default toolbox for this step
  - `:response_format` - JSON schema to constrain output
  - `:keep_prompt?` - if true, the prompt remains in message history (default false)
  """
  @spec completion(step_name, binary, keyword) :: completion_step
  def completion(name, prompt, opts \\ []) do
    %{
      type: :completion,
      name: name,
      prompt: prompt,
      model: Keyword.get(opts, :model),
      toolbox: Keyword.get(opts, :toolbox),
      response_format: Keyword.get(opts, :response_format),
      keep_prompt?: Keyword.get(opts, :keep_prompt?, false)
    }
  end

  @doc """
  Creates a delegate step - spawns a sub-agent and injects its response into
  the parent conversation. The `args_builder` function receives the current
  state and must return the args map passed to the sub-agent's `get_response/1`.
  """
  @spec delegate(step_name, module, (t -> map)) :: delegate_step
  def delegate(name, agent_module, args_builder) do
    %{
      type: :delegate,
      name: name,
      agent: agent_module,
      args_builder: args_builder
    }
  end

  # ---------------------------------------------------------------------------
  # State accessors
  # ---------------------------------------------------------------------------

  @doc """
  Sets a value in the `internal` map. `key` may be a single atom or a list of
  atoms (nested path per `put_in/3` semantics). When passing a list, all
  intermediate keys must already exist.
  """
  @spec put_state(state :: t, key :: atom | list, value :: any) :: t
  def put_state(state, key, value) when is_atom(key) do
    %{state | internal: Map.put(state.internal, key, value)}
  end

  def put_state(state, keys, value) when is_list(keys) do
    %{state | internal: put_in(state.internal, keys, value)}
  end

  @doc """
  Retrieves a value from the `internal` map. `key` may be a single atom or a
  list of atoms (nested path per `get_in/2` semantics). Returns
  `{:error, :not_found}` when any key in the path is missing.
  """
  @spec get_state(state :: t, key :: atom | list) :: {:ok, any} | {:error, :not_found}
  def get_state(state, key) when is_atom(key) do
    case Map.fetch(state.internal, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :not_found}
    end
  end

  def get_state(state, keys) when is_list(keys) do
    case get_in(state.internal, keys) do
      nil -> {:error, :not_found}
      value -> {:ok, value}
    end
  end

  # ---------------------------------------------------------------------------
  # Step queue manipulation - available for use in callbacks
  # ---------------------------------------------------------------------------

  @doc "Prepend steps to the front of the queue (next to execute)."
  @spec push_steps(t, [step | [step]]) :: t
  def push_steps(state, new_steps) do
    %{state | steps: new_steps ++ state.steps}
  end

  @doc "Append steps to the end of the queue."
  @spec append_steps(t, [step | [step]]) :: t
  def append_steps(state, new_steps) do
    %{state | steps: state.steps ++ new_steps}
  end

  # ---------------------------------------------------------------------------
  # Execution engine
  # ---------------------------------------------------------------------------

  @doc """
  Runs the composite agent to completion. Calls `init/1` on the implementation
  module, then processes steps from the queue until it's empty or an
  unrecoverable error occurs.

  Returns `{:ok, final_response}` or `{:error, reason}`.
  """
  @spec run(module, map) :: {:ok, binary} | {:error, any}
  def run(impl, args) do
    case impl.init(args) do
      {:ok, state} -> execute_loop(impl, state)
      {:error, _} = error -> error
    end
  end

  defp execute_loop(_impl, %{steps: []} = state) do
    {:ok, state.response}
  end

  defp execute_loop(impl, %{steps: [next | rest]} = state) do
    state = %{state | steps: rest}
    execute_step(impl, state, next)
  end

  # ---------------------------------------------------------------------------
  # Parallel group - a list of steps to run concurrently
  # ---------------------------------------------------------------------------
  defp execute_step(impl, state, steps) when is_list(steps) do
    state = Enum.reduce(steps, state, fn step, acc -> impl.on_step_start(step, acc) end)

    parent_pool = HttpPool.get()

    tasks =
      Enum.map(steps, fn step ->
        Services.Globals.Spawn.async(fn ->
          HttpPool.set(parent_pool)
          run_single_step(state, step)
        end)
      end)

    results =
      try do
        Task.await_many(tasks, :infinity)
      rescue
        e ->
          # If any parallel task crashes, map all results to errors so the
          # on_error callback gets a chance to handle it gracefully.
          Enum.map(steps, fn _ -> {:error, Exception.message(e)} end)
      end

    # Collect results and inject into the conversation. Each parallel step's
    # response becomes a user message with a header so the agent can identify
    # which specialist produced it. Next-steps from all parallel results are
    # collected and applied after the full reduction to avoid interleaving.
    {state, errors, pending_next_steps} =
      Enum.zip(steps, results)
      |> Enum.reduce({state, [], []}, fn
        {step, {:ok, response, messages}}, {acc, errs, nexts} ->
          # Completion step in parallel - append only messages beyond what was
          # in the shared state before this step ran, so parallel completions
          # don't clobber each other. Length-based slicing avoids the fragility
          # of list subtraction on structurally similar messages.
          new_msgs = Enum.drop(messages, length(acc.messages))
          acc = %{acc | messages: acc.messages ++ new_msgs, response: response}
          acc = impl.on_step_complete(step, acc)

          case acc.error do
            nil ->
              next = impl.get_next_steps(step, acc)
              {acc, errs, nexts ++ next}

            reason ->
              {acc, [{step, reason} | errs], nexts}
          end

        {step, {:ok, response}}, {acc, errs, nexts} ->
          # Delegate step - inject response as a labeled user message
          label = step_label(step)
          msg = AI.Util.user_msg("## #{label}\n\n#{response}")
          acc = %{acc | messages: acc.messages ++ [msg], response: response}
          acc = impl.on_step_complete(step, acc)

          case acc.error do
            nil ->
              next = impl.get_next_steps(step, acc)
              {acc, errs, nexts ++ next}

            reason ->
              {acc, [{step, reason} | errs], nexts}
          end

        {step, {:error, reason}}, {acc, errs, nexts} ->
          label = step_label(step)
          msg = AI.Util.user_msg("## #{label}\n\n**FAILED**: #{inspect(reason)}")
          acc = %{acc | messages: acc.messages ++ [msg]}
          {acc, [{step, reason} | errs], nexts}
      end)

    # Apply all collected next-steps at once after reduction
    state = push_steps(state, pending_next_steps)

    case errors do
      [] ->
        execute_loop(impl, state)

      [{step, reason} | _] ->
        state = %{state | error: reason}

        case impl.on_error(step, reason, state) do
          {:retry, state} -> execute_step(impl, state, steps)
          {:skip, state} -> execute_loop(impl, %{state | error: nil})
          {:halt, state} -> {:error, state.error}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Single sequential step
  # ---------------------------------------------------------------------------
  defp execute_step(impl, state, step) do
    state = impl.on_step_start(step, state)

    case run_single_step(state, step) do
      {:ok, response, messages} ->
        state = %{state | response: response, messages: messages, error: nil}
        state = impl.on_step_complete(step, state)

        case state.error do
          nil ->
            next = impl.get_next_steps(step, state)
            state = push_steps(state, next)
            execute_loop(impl, state)

          reason ->
            case impl.on_error(step, reason, state) do
              {:retry, state} -> execute_step(impl, state, step)
              {:skip, state} -> execute_loop(impl, %{state | error: nil})
              {:halt, state} -> {:error, state.error}
            end
        end

      {:ok, response} ->
        state = %{state | response: response, error: nil}
        state = impl.on_step_complete(step, state)

        case state.error do
          nil ->
            next = impl.get_next_steps(step, state)
            state = push_steps(state, next)
            execute_loop(impl, state)

          reason ->
            case impl.on_error(step, reason, state) do
              {:retry, state} -> execute_step(impl, state, step)
              {:skip, state} -> execute_loop(impl, %{state | error: nil})
              {:halt, state} -> {:error, state.error}
            end
        end

      {:error, reason} ->
        state = %{state | error: reason}

        case impl.on_error(step, reason, state) do
          {:retry, state} -> execute_step(impl, state, step)
          {:skip, state} -> execute_loop(impl, %{state | error: nil})
          {:halt, state} -> {:error, state.error}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Step execution primitives
  # ---------------------------------------------------------------------------

  # Completion step - a turn in this agent's conversation. Runs the prompt,
  # manages message history (prompt injection/removal), and returns the
  # response along with the updated message list (which includes any tool
  # call messages generated during the completion).
  defp run_single_step(state, %{type: :completion} = step) do
    model = step.model || state.model
    toolbox = step.toolbox || state.toolbox

    state.agent
    |> AI.Agent.get_completion(
      model: model,
      toolbox: toolbox,
      messages: state.messages ++ [AI.Util.system_msg(step.prompt)],
      response_format: step.response_format,
      log_tool_calls: true
    )
    |> case do
      {:ok, %{response: response, messages: messages}} ->
        messages =
          if step.keep_prompt? do
            messages
          else
            Enum.reject(messages, fn msg ->
              Map.get(msg, :role) == "system" and Map.get(msg, :content, "") == step.prompt
            end)
          end
          |> Enum.concat([AI.Util.assistant_msg(response)])

        {:ok, response, messages}

      {:error, %{response: response}} ->
        {:error, response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Delegate step - spawn a sub-agent with its own conversation.
  defp run_single_step(state, %{type: :delegate} = step) do
    args = step.args_builder.(state)

    step.agent
    |> AI.Agent.new()
    |> AI.Agent.get_response(args)
    |> case do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp step_label(%{name: name}) do
    name
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end
end

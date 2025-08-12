defmodule AI.Agent.Code.Common do
  defstruct [
    :name,
    :model,
    :toolbox,
    :request,
    :response,
    :error,
    :messages,
    :internal
  ]

  @default_name "Ari Doneyet"

  @type task :: Services.Task.task()
  @type new_task :: %{label: binary, detail: binary}

  @typedoc """
  Common state for AI agents that work with code. Includes an `internal` `map`
  that can be used to store additional state that is specific to the
  implementation.
  """
  @type t :: %__MODULE__{
          name: binary,
          model: AI.Model.t(),
          toolbox: AI.Tools.toolbox(),
          request: binary,
          response: binary | nil,
          error: any,
          messages: AI.Util.msg_list(),
          internal: map
        }

  @doc """
  Creates a new state for an AI agent that works with code. The initial message
  list includes the system prompt and the user prompt, as provided.
  """
  @spec new(
          model :: AI.Model.t(),
          toolbox :: AI.Tools.toolbox(),
          system_prompt :: binary,
          user_prompt :: binary
        ) :: t
  def new(model, toolbox, system_prompt, user_prompt) do
    name =
      with {:ok, name} <- Services.NamePool.checkout_name() do
        name
      else
        _ -> @default_name
      end

    %__MODULE__{
      name: name,
      model: model,
      toolbox: toolbox,
      request: user_prompt,
      internal: %{},
      response: nil,
      error: nil,
      messages: [
        AI.Util.system_msg(system_prompt),
        AI.Util.user_msg(user_prompt)
      ]
    }
  end

  @doc """
  Sets the `internal`, implementation-specific state for the AI agent. `key`
  may be either a single atom or a list of atoms representing a path to a value
  in the `internal` map (per `put_in/3` semantics).

  When passing a list of keys, all keys must exist within the nested structure.
  An exception will be thrown (by `put_in/3`) if any key is missing.

  Examples:
  ```
  # Set a single value
  state = AI.Agent.Code.Common.put_state(state, :blarg, "how now brown beaurocrat")

  # Set a nested value
  state = AI.Agent.Code.Common.put_state(state, [:blarg, :foo], "bar")
  ```
  """
  @spec put_state(
          state :: t,
          key :: atom | list,
          value :: any
        ) :: t
  def put_state(state, key, value) when is_atom(key) do
    %{state | internal: Map.put(state.internal, key, value)}
  end

  def put_state(state, keys, value) when is_list(keys) do
    %{state | internal: put_in(state.internal, keys, value)}
  end

  @doc """
  Retrieves a value from the `internal` state of the AI agent. `key` may be
  either a single atom or a list of atoms representing a path to a value in the
  `internal` map (per `get_in/2` semantics).

  When passing a list of keys, all keys must exist within the nested structure.
  `{:error, :not_found}` will be returned if any key is missing.

  Examples:
  ```
  # Get a single value
  {:ok, value} = AI.Agent.Code.Common.get_state(state, :blarg)

  # Get a nested value
  {:ok, value} = AI.Agent.Code.Common.get_state(state, [:blarg, :foo])
  ```
  """
  @spec get_state(
          state :: t,
          key :: atom | list
        ) :: {:ok, any} | {:error, any}
  def get_state(state, key) when is_atom(key) do
    with {:ok, value} <- Map.fetch(state.internal, key) do
      {:ok, value}
    else
      :error -> {:error, :not_found}
    end
  end

  def get_state(state, keys) when is_list(keys) do
    get_in(state.internal, keys)
    |> case do
      nil -> {:error, :not_found}
      value -> {:ok, value}
    end
  end

  @doc """
  Executes a completion request using the AI model specified in the state. The
  `prompt` is appended to the existing messages in the state as a system
  message. Unless `keep_prompt?` is `true`, the system prompt will be removed
  from the messages after the completion is received to keep the cascade of
  instructions clean.
  """
  @spec get_completion(
          state :: t,
          prompt :: binary,
          response_format :: map | nil,
          keep_prompt? :: boolean
        ) :: t
  def get_completion(state, prompt, response_format \\ nil, keep_prompt? \\ false) do
    AI.Completion.get(
      model: state.model,
      toolbox: state.toolbox,
      messages: state.messages ++ [AI.Util.system_msg(prompt)],
      response_format: response_format,
      log_tool_calls: true
    )
    |> case do
      {:ok, %{response: response, messages: messages}} ->
        # If keep_prompt? is false, we remove the last system message,
        # which is the prompt we added above.
        messages =
          if keep_prompt? do
            messages
          else
            messages
            |> Enum.reject(&(Map.get(&1, :content, "") == prompt))
          end
          |> Enum.concat([AI.Util.assistant_msg(response)])

        %{state | response: response, messages: messages}

      {:error, %{response: response}} ->
        %{state | error: response}

      {:error, reason} ->
        %{state | error: reason}
    end
  end

  @doc """
  Returns a string that describes the values and principles that guide the code
  agent's design and implementation decisions. This is used to inform the AI
  agent's behavior and responses, ensuring that it adheres to a consistent set
  of coding standards and practices.
  """
  @spec coder_values_prompt() :: binary
  def coder_values_prompt do
    """
    **You hold strong opinions about proper code structure and design:**
    - The Prime Directive: Proper Separation of Concerns
    - "Opinionated" means "I failed to imagine how this would be used"
    - Keep your special cases off of my API
    - Do the dishes as we cook
    - I may not like the style conventions, but the most important thing is consistency
    - Comments are for humans (and LLMs, apparently), and should walk the reader through the code, explaining why the feature behaves as it does.
      If the reader hides all of the code, the comments should still tell a complete story.
    - There is a level of abstraction that is the "sweet spot" between DRY, KISS, YAGNI, and unnecessary dependency.
    - Magic is for Tim the Enchanter, not for code.
      That said, dev joy keeps the user happy.
    - Unit tests NEVER reach out onto the network. Those are called Integration Tests.
      Unit tests ONLY test the code they are written for, not the code that calls it, even if that is the only way to reach the function being tested.
    - Features should be organized to be separate from each other.
      Integration points call into features.
      Features are NEVER sprinkled across the code base.
    """
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------
  @spec add_follow_up_tasks(Services.Task.list_id(), list(new_task)) :: :ok
  def add_follow_up_tasks(list_id, new_tasks) do
    Enum.each(new_tasks, &add_follow_up_task(list_id, &1))
    :ok
  end

  @spec add_follow_up_task(Services.Task.list_id(), new_task) :: any
  def add_follow_up_task(list_id, %{label: label, detail: detail}) do
    Services.Task.push_task(list_id, label, detail)
  end

  @spec report_task_stack(state :: t) :: any
  def report_task_stack(state) do
    with {:ok, task_list_id} <- get_state(state, :task_list_id) do
      UI.info("#{state.name} is working", Services.Task.as_string(task_list_id))
    end
  end

  @spec format_new_tasks(list(new_task)) :: binary
  def format_new_tasks(new_tasks) do
    new_tasks
    |> Enum.map(&"- #{&1.label}")
    |> Enum.join()
    |> case do
      "" -> "No follow-up tasks were identified."
      tasks -> tasks
    end
  end

  @spec report_task_outcome(
          task :: task,
          error :: binary,
          outcome :: binary,
          follow_up_tasks :: list(new_task)
        ) :: :ok
  def report_task_outcome(task, "", outcome, follow_up_tasks) do
    UI.info(
      "Task completed",
      """
      # Task
      #{task.id}

      # Outcome
      #{outcome}

      # Follow-up Tasks
      #{follow_up_tasks |> format_new_tasks()}
      """
    )
  end

  def report_task_outcome(task, error, outcome, follow_up_tasks) do
    UI.error(
      "Task implementation failed",
      """
      # Task
      #{task.id}

      # What Went Wrong
      **Error:** #{error}

      #{outcome}

      # Follow-up Tasks
      #{follow_up_tasks |> format_new_tasks()}
      """
    )
  end
end

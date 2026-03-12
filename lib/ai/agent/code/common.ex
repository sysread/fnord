defmodule AI.Agent.Code.Common do
  @moduledoc """
  State management for code-oriented agents (planner, implementor, validator).
  Provides multi-turn conversation primitives and task management helpers.

  This module manages its own struct and completion loop independently of
  `AI.Agent.Composite`. The code agents use this directly rather than
  implementing the Composite behaviour.
  """

  defstruct [
    :agent,
    :model,
    :toolbox,
    :request,
    :response,
    :error,
    :messages,
    :internal
  ]

  @type task :: Services.Task.task()
  @type new_task :: %{label: binary, detail: binary}

  @type t :: %__MODULE__{
          agent: AI.Agent.t(),
          model: AI.Model.t(),
          toolbox: AI.Tools.toolbox(),
          request: binary,
          response: binary | nil,
          error: any,
          messages: AI.Util.msg_list(),
          internal: map
        }

  # ---------------------------------------------------------------------------
  # Initialization
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new state for a code agent. The initial message list contains the
  system prompt and the user prompt.
  """
  @spec new(AI.Agent.t(), AI.Model.t(), AI.Tools.toolbox(), binary, binary) :: t
  def new(agent, model, toolbox, system_prompt, user_prompt) do
    %__MODULE__{
      agent: agent,
      model: model,
      toolbox: toolbox,
      request: user_prompt,
      internal: %{},
      response: nil,
      error: nil,
      messages: [
        AI.Util.system_msg(AI.Util.project_context()),
        AI.Util.system_msg(system_prompt),
        AI.Util.user_msg(user_prompt)
      ]
    }
  end

  # ---------------------------------------------------------------------------
  # Internal state accessors
  # ---------------------------------------------------------------------------

  @spec put_state(t, atom | list, any) :: t
  def put_state(state, key, value) when is_atom(key) do
    %{state | internal: Map.put(state.internal, key, value)}
  end

  def put_state(state, keys, value) when is_list(keys) do
    %{state | internal: put_in(state.internal, keys, value)}
  end

  @spec get_state(t, atom | list) :: {:ok, any} | {:error, :not_found}
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
  # Completion
  # ---------------------------------------------------------------------------

  @doc """
  Executes a completion request. The `prompt` is appended as a system message,
  then removed after the completion (unless `keep_prompt?` is true). The
  assistant's response is always appended to the message history.
  """
  @spec get_completion(t, binary, map | nil, boolean) :: t
  def get_completion(state, prompt, response_format \\ nil, keep_prompt? \\ false) do
    state.agent
    |> AI.Agent.get_completion(
      model: state.model,
      toolbox: state.toolbox,
      messages: state.messages ++ [AI.Util.system_msg(prompt)],
      response_format: response_format,
      log_tool_calls: true
    )
    |> case do
      {:ok, %{response: response, messages: messages}} ->
        messages =
          if keep_prompt? do
            messages
          else
            Enum.reject(messages, &(Map.get(&1, :content, "") == prompt))
          end
          |> Enum.concat([AI.Util.assistant_msg(response)])

        %{state | response: response, messages: messages}

      {:error, %{response: response}} ->
        %{state | error: response}

      {:error, reason} ->
        %{state | error: reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Coder values prompt
  # ---------------------------------------------------------------------------

  @spec coder_values_prompt() :: binary
  def coder_values_prompt do
    """
    **You hold strong opinions about proper code structure and design:**
    - The Prime Directive: Proper Separation of Concerns
    - "Opinionated" means "I failed to imagine how this would be used"
    - Keep your special cases off of my API
    - Do the dishes as we cook
    - I may not like the style conventions, but the most important thing is consistency
    - Comments are for humans (and LLMs!), and should walk the reader through the code, explaining why the feature behaves as it does.
      They should explain how each significant step fits into the larger system.
      If the reader hides all of the code, the comments should frame a narrative outline of the flow of logic, state, and data through the module.
      Leave existing comments and docstrings alone! That is, unless they are clearly incorrect or misleading.
    - There is a level of abstraction that is the "sweet spot" between DRY, KISS, YAGNI, and unnecessary dependency.
    - Magic is for Tim the Enchanter, not for code.
      That said, dev joy keeps the user happy.
    - BEFORE modifying an interface (eg pkg/fn/endpoint), ALWAYS use your tools to examine existing use cases.
      Based on the intent of a change, you must decide whether to update existing callers, create a new interface, or ask for clarification.
      When in doubt, create a new interface... with tests.
    - Unit tests NEVER reach out onto the network. Those are called Integration Tests.
      Unit tests ONLY test the code they are written for, not the code that calls it, even if that is the only way to reach the function being tested.
    - Features should be organized to be separate from each other.
      Integration points call into features.
      Features are NEVER sprinkled across the code base.
    - NEVER assume that a given library is available!
      ALWAYS check that the library is present.
      Never add new libraries that the user did not expressly request or approve.
    - Reachability and Preconditions:
      - Before flagging a bug or risk, confirm it is reachable in current control flow.
      - Identify real callers using file indexes and call graph tools; cite concrete entry points.
      - Inspect pattern matches, guards, and prior validation layers that constrain inputs and states.
      - Classification:
        - Concrete bug: provide the exact path (caller -> callee), show which preconditions are satisfied, and why a failing state can occur now.
        - Potential issue: if reachability depends on changes or bypassing a guard, label as potential and specify exactly what would have to change.
      - Cite minimal evidence: file paths, symbols, relevant snippets, and the shortest proof chain.
    - ALWAYS check for READMEs, CONTRIBUTING files, AGENTS.md, CLAUDE.md, etc., to identify conventions and expectations for the area(s) of the code you are working on.
    - Testability and environment rules:
      - Never add test-only branches or functions in production code.
      - Prefer testable structure and DI: extract production helpers or adapters and test through public APIs and injected boundaries (UI, Services, adapters).
        Do not expose internals for testing.
      - If behavior is not reachable via tests, state this clearly and propose a minimal refactor to make it testable.
        Do not add a test-only shim.
      - Integration tests should assert observable effects at boundaries (e.g., UI output, service calls, persisted data) rather than calling private internals.
      - If you cannot design a production path reachable by tests, stop and surface a follow-up task describing the minimal refactor to enable testability.
    - Quick check before proposing or writing code:
      1) Is any part of the change gated on logic that tries to guess whether it is running under test? If yes, stop.
      2) Can this behavior be exercised via public APIs and DI boundaries? If not, specify the refactor needed.
      3) Do tests validate observable production behavior (not private hooks or test-only functions)? If no, adjust the plan.

    NEVER LEAVE AI SLOP COMMENTS THAT DESCRIBE THE CHANGES BEING MADE!
    SERIOUSLY, YOU HAVE _GOT_ TO STOP THAT CRAP.
    IT'S NOT USEFUL AND IT ERODES TRUST IN YOUR ABILITY TO MAKE CODE CHANGES.
    ```
    """
  end

  # ---------------------------------------------------------------------------
  # Task management helpers
  # ---------------------------------------------------------------------------

  @spec add_tasks(Services.Task.list_id(), list(new_task)) :: :ok
  def add_tasks(list_id, new_tasks) do
    Enum.each(new_tasks, &add_task(list_id, &1))
    :ok
  end

  @spec add_task(Services.Task.list_id(), new_task) :: any
  def add_task(list_id, %{label: label, detail: detail}) do
    Services.Task.add_task(list_id, label, detail)
  end

  @spec report_task_stack(state :: t) :: any
  def report_task_stack(state) do
    with {:ok, task_list_id} <- get_state(state, :task_list_id) do
      UI.report_from(state.agent.name, "Working", Services.Task.as_string(task_list_id))
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

  @spec report_task_outcome(t, task, binary, binary, list(new_task)) :: :ok
  def report_task_outcome(state, task, "", outcome, follow_up_tasks) do
    UI.report_from(
      state.agent.name,
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

  def report_task_outcome(state, task, error, outcome, follow_up_tasks) do
    UI.report_from(
      state.agent.name,
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

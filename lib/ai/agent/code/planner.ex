defmodule AI.Agent.Code.Planner do
  @model AI.Model.reasoning(:high)

  @prompt """
  You are the Code Planner, an AI agent within a larger system.
  Your role is to plan the implementation of a code change requested by the Coordinating Agent.

  You hold strong opinions about proper code structure and design:
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

  # ----------------------------------------------------------------------------
  # Behaviour Implementation
  # ----------------------------------------------------------------------------
  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(%{request: request}) do
    request
    |> new()
    |> research()
    |> visualize()
    |> plan()
    |> case do
      %{error: nil, list_id: list_id} -> {:ok, list_id}
      %{error: error} -> {:error, error}
    end
  end

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------
  defstruct [
    :request,
    :error,
    :list_id,
    :response,
    :messages
  ]

  @type t :: %__MODULE__{
          request: binary,
          error: any,
          list_id: non_neg_integer | nil,
          response: binary | nil,
          messages: AI.Util.msg_list()
        }

  @spec new(binary) :: t
  defp new(request) do
    %__MODULE__{
      request: request,
      error: nil,
      list_id: nil,
      response: nil,
      messages: [
        AI.Util.system_msg(@prompt),
        AI.Util.user_msg(request)
      ]
    }
  end

  # ----------------------------------------------------------------------------
  # Research
  # ----------------------------------------------------------------------------
  @research_prompt """
  Read the request and research that area of the code base, including unrelated but adjacent code.
  It is of the utmost importance that you can identify unintended consequences of the requested changes.
  Familiarize yourself with the conventions and patterns used in this area of the project.

  # Response Template
  Use the following template for your response (without the markdown fences):
  ```
  # ANALYSIS

  ## SYNOPSIS
  [...]

  ## DEFINITIONS AND COMPONENTS
  [...]

  ## RELATED FILES
  [...]

  ## TEST COVERAGE
  [...]

  ## DETAILED ANALYSIS
  [...]

  ## UPSTREAM DEPENDENCIES
  [...]

  ## DOWNSTREAM DEPENDENCIES
  [...]

  ## POTENTIAL SIDE EFFECTS
  [...]

  ## EDGE CASES
  [...]

  ## RELEVANT CONVENTIONS
  [...]
  ```
  """

  @spec research(t) :: t
  defp research(%{error: nil} = state) do
    UI.debug("Researching change request", state.request)
    get_completion(state, new_messages: [AI.Util.system_msg(@research_prompt)])
  end

  # ----------------------------------------------------------------------------
  # Visualize
  # ----------------------------------------------------------------------------
  @visualize_prompt """
  Consider the *shape* of the data.
  Consider the *flow* of state through the affected components.
  If you were writing the code from scratch, how would you have structured it?
  Imagine the ideal implementation of the requested change.
  Consider the proper separation of concerns.
  Now, compare your Blue Sky Implementation with the current state of the code.
  Murphy dictates that the perfect implementation will not be possible, but you go to war with the army you *have*.
  What is the closest you can get to the ideal implementation that still dovetails into the code as it is?
  Respond with your Near Ideal Implementation, including any relevant files, functions, or components that may be affected by this change.
  """

  @spec visualize(t) :: t
  defp visualize(%{error: nil} = state) do
    UI.debug("Considering the flow of the affected components", state.request)
    get_completion(state, new_messages: [AI.Util.system_msg(@visualize_prompt)])
  end

  defp visualize(state), do: state

  # ----------------------------------------------------------------------------
  # Plan
  # ----------------------------------------------------------------------------
  @plan_prompt """
  Compare the current state of the code with your solution.
  The implementation will result from a "cascade" of changes, where each layers on top of the previous one.
  What atomic steps can you take to get from the current state to your solution?
  Pay special attention to ordering the changes in a logical fashion.

  Each task must have:
  - A single, concrete goal
  - Clear, unambiguous definition of scope
  - Clear acceptance criteria
  - A detailed description of the change to be made, including any relevant code snippets, examples, and file paths
  - An "anchor" that describes the location in unambiguous terms (note that line numbers change across tasks, so anchors must reference components, syntax, or other relatively stable identifiers)
  """

  @plan_response_format %{
    type: "json_schema",
    json_schema: %{
      name: "plan_steps",
      description: """
      A JSON object containing either an error or a list of atomic steps to
      implement the requested change.
      """,
      schema: %{
        type: "object",
        required: [],
        additionalProperties: false,
        properties: %{
          error: %{
            type: "string",
            description: """
            An error message indicating why the plan could not be generated,
            including guidance on how to resolve the issue.
            """
          },
          steps: %{
            type: "array",
            items: %{
              type: "object",
              description: "List of steps if plan generation succeeded.",
              required: ["label", "detail"],
              additionalProperties: false,
              properties: %{
                label: %{
                  type: "string",
                  description: """
                  A short, descriptive label for the step, summarizing the
                  action to be taken.
                  """
                },
                detail: %{
                  type: "string",
                  description: """
                  A detailed description of the step, including:
                    - A single, concrete goal
                    - Clear, unambiguous definition of scope
                    - Clear acceptance criteria
                    - Detailed description of the change, with relevant code snippets, examples, and file paths
                    - An 'anchor' that describes the location in unambiguous terms.
                  """
                }
              }
            }
          }
        }
      }
    }
  }

  @spec plan(t) :: t
  defp plan(%{error: nil} = state) do
    UI.debug("Identifying steps required to reach the desired state", state.request)

    get_completion(state,
      new_messages: [AI.Util.system_msg(@plan_prompt)],
      response_format: @plan_response_format
    )
    |> case do
      %{error: nil, response: response} ->
        response
        |> Jason.decode()
        |> case do
          {:error, reason} ->
            %{state | error: reason}

          {:ok, %{"error" => error}} ->
            %{state | error: error}

          {:ok, %{"steps" => steps}} ->
            list_id = TaskServer.start_list()

            Enum.each(steps, fn %{"label" => label, "detail" => detail} ->
              TaskServer.add_task(list_id, label, detail)
            end)

            %{state | list_id: list_id}
        end
    end
  end

  defp plan(state), do: state

  # ----------------------------------------------------------------------------
  # Innards
  # ----------------------------------------------------------------------------
  @spec get_completion(t, keyword) :: t
  defp get_completion(state, opts) do
    toolbox = Keyword.get(opts, :toolbox, AI.Tools.all_tools())
    messages = state.messages ++ Keyword.get(opts, :new_messages, [])
    response_format = Keyword.get(opts, :response_format, nil)

    AI.Completion.get(
      model: @model,
      toolbox: toolbox,
      messages: messages,
      response_format: response_format,
      log_msgs: true,
      log_tool_calls: true
    )
    |> case do
      {:ok, %{response: response, messages: messages}} ->
        msg = AI.Util.assistant_msg(response)
        %{state | response: response, messages: messages ++ [msg]}

      {:error, %{response: response}} ->
        %{state | error: response}

      {:error, reason} ->
        %{state | error: reason}
    end
  end
end

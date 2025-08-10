defmodule AI.Agent.Code.Planner do
  alias AI.Agent.Code.Common

  @type t :: Common.t()

  @model AI.Model.reasoning(:high)

  @prompt """
  You are the Code Planner, an AI agent within a larger system.
  Your role is to plan the implementation of a code change requested by the Coordinating Agent.

  #{AI.Agent.Code.Common.coder_values_prompt()}
  """

  # ----------------------------------------------------------------------------
  # Behaviour Implementation
  # ----------------------------------------------------------------------------
  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(%{request: request}) do
    tools =
      AI.Tools.all_tools()
      |> AI.Tools.with_rw_tools()

    Common.new(@model, tools, @prompt, request)
    |> research()
    |> visualize()
    |> plan()
    |> case do
      %{error: nil, internal: %{list_id: list_id}} -> {:ok, list_id}
      %{error: error} -> {:error, error}
    end
  end

  # ----------------------------------------------------------------------------
  # Research
  # ----------------------------------------------------------------------------
  @research_prompt """
  Read the request and research that area of the code base, including unrelated but adjacent code.
  It is of the utmost importance that you can identify unintended consequences of the requested changes.
  Familiarize yourself with the conventions and patterns used in this area of the project.

  # Response Template
  Use the following template for your response (without the markdown fences).
  For each section, ensure that you **ONLY report CONCRETE findings from your research, not abstract concepts.**
  Abstract warnings will only confuse the Implementing Agent and pollute their context window with unhelpful noise.

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
  defp research(%{error: nil, name: name} = state) do
    UI.info("#{name} is investigating a change request")
    Common.get_completion(state, @research_prompt)
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
  Respond with your near ideal implementation, including any relevant files, functions, or components that may be affected by this change.
  """

  @spec visualize(t) :: t
  defp visualize(%{error: nil, name: name} = state) do
    UI.info("#{name} is brainstorming")
    Common.get_completion(state, @visualize_prompt)
  end

  defp visualize(state), do: state

  # ----------------------------------------------------------------------------
  # Plan
  # ----------------------------------------------------------------------------
  @plan_prompt """
  Compare the current state of the code with your solution.
  The implementation will result from a "cascade" of changes, where each layers on top of the previous one.
  Consider the types of changes that LLMs tend to struggle with.
  Design your plan to minimize the risk of compounding errors and mitigate the weaknesses of LLMs when writing code.
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
                  - An 'anchor' that describes the location in unambiguous terms
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
  defp plan(state, invalid_format? \\ false)

  defp plan(%{error: nil, name: name} = state, invalid_format?) do
    UI.info("#{name} is identifying steps required to reach the desired state", state.request)

    prompt =
      if invalid_format? do
        """
        #{@plan_prompt}
        -----
        Your previous response was not in the correct format.
        Pay special attention to required fields and data types.
        Please adhere to the specified JSON schema.
        Try your response again, ensuring it matches the required format.
        """
      else
        @plan_prompt
      end

    state
    |> Common.get_completion(prompt, @plan_response_format)
    |> case do
      %{error: nil, response: response} ->
        response
        |> Jason.decode(keys: :atoms)
        |> case do
          {:error, reason} ->
            %{state | error: reason}

          {:ok, %{error: error}} ->
            %{state | error: error}

          {:ok, %{steps: steps}} ->
            list_id = TaskServer.start_list()

            Enum.each(steps, fn %{label: label, detail: detail} ->
              TaskServer.add_task(list_id, label, detail)
            end)

            Common.put_state(state, :list_id, list_id)

          _ ->
            plan(state, true)
        end

      state ->
        state
    end
  end

  defp plan(state, _), do: state
end

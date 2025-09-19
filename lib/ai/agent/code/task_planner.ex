defmodule AI.Agent.Code.TaskPlanner do
  alias AI.Agent.Code.Common

  @type t :: Common.t()

  @model AI.Model.reasoning(:high)

  @prompt """
  Before planning, check for README.md, CLAUDE.md, and AGENTS.md in the project root and current directory.
  Use the file_contents_tool to read each.
  If both project and CWD versions exist, prefer the CWD file for local context.

  You are the Code Planner, an AI agent within a larger system.
  Your role is to plan the implementation of a code change requested by the Coordinating Agent.

  Use the `notify_tool` regularly to convey your reasoning, findings, and progress. For example:
  - "I am checking out nearby files to understand the conventions used in this area of the code base."
  - "I want to understand the flow of state through the affected components."
  - "I need to double-check the test coverage of this module and make sure it is sufficient before I start making changes willy-nilly."
  - "Interesting! I found another function that does the exact same thing as we need to do, but in a different module. Let me consider whether reusing that function is appropriate."

  #{AI.Agent.Code.Common.coder_values_prompt()}
  """

  # ----------------------------------------------------------------------------
  # Behaviour Implementation
  # ----------------------------------------------------------------------------
  @behaviour AI.Agent
  @impl AI.Agent
  def get_response(%{agent: agent, request: request}) do
    hints =
      if Settings.get_hint_docs_enabled?() and Settings.get_hint_docs_auto_inject?() do
        AI.Notes.ExternalDocs.get_docs()
        |> AI.Notes.ExternalDocs.format_hints()
      else
        ""
      end

    request = hints <> "\n" <> request

    tools =
      AI.Tools.all_tools()
      |> AI.Tools.with_rw_tools()

    agent
    |> Common.new(@model, tools, @prompt, request)
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
  defp research(%{error: nil} = state) do
    UI.report_from(state.agent.name, "Investigating a change request")
    state = Common.get_completion(state, @research_prompt)

    if state.error do
      UI.report_from(
        state.agent.name,
        "Research failed",
        "#{inspect(state.error)}\n\n#{state.response || "<no response>"}"
      )
    end

    state
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
  For larger repos and more complex applications, prioritize loose coupling and high cohesion to minimize the blast radius of changes.
  For smaller repos and stand-alone libraries, prioritize simplicity and directness to minimize cognitive load.
  Don't let the perfect be the enemy of the good.
  What is the closest you can get to the ideal implementation that still dovetails into the code as it is?
  Respond with your near ideal implementation, including any relevant files, functions, or components that may be affected by this change.
  """

  @spec visualize(t) :: t
  @spec visualize(t) :: t
  defp visualize(%{error: nil} = state) do
    UI.report_from(state.agent.name, "Brainstorming solutions")
    state = Common.get_completion(state, @visualize_prompt)

    if state.error do
      UI.report_from(
        state.agent.name,
        "Visualization failed",
        "#{inspect(state.error)}\n\n#{state.response || "<no response>"}"
      )
    end

    state
  end

  # ----------------------------------------------------------------------------
  # Plan
  # ----------------------------------------------------------------------------
  @plan_prompt """
  Consider the types of changes that LLMs tend to struggle with.
  Design your plan to minimize the risk of compounding errors and mitigate the weaknesses of LLMs when writing code.

  If new files, modules, or packages are required, carefully consider where they should be placed for consistent organization, reduce surprise, and maintain clear boundaries between components.
  Weigh the benefits of editing existing code against the risks of introducing bugs or breaking existing functionality.
  Given the novelty of AI-generated code, it may be better to create a new "feature package" in an isolated location and just call it from existing code to mitigate risk and dependency.
  Incidentally, this ia also good practice for biological programmers, as it reduces the surface area for bugs and makes writing unit tests much simpler.

  Compare the current state of the code with your solution.
  Identify the changes in terms of component interfaces and contracts.
  The first steps are to create test cases that validate the desired change.
  Next, identify the logical steps required to implement the change.
  In your instructions for each step, identify whether the unit test(s) created in the first step(s) should pass after this step is complete.
  Break the change down into a series of logical dependencies, just as you would when writing a program in prolog.
  Each step builds on the previous, resulting in a cascade of changes that, once implemented, will result in the desired state.

  Coding LLMs have difficulty when assumptions do not match the actual state of the code:
  - Include enough context about the change that the LLM can make informed
    decisions if adaptations are needed.
  - Identify assumptions about the expected state of the code at each step; the
    LLM is able to add follow-up tasks when it finds that the assumptions do
    not match reality.
  - For each step, it may help to summarize the previous work leading up to the
    current step, what the next steps will be, as well as how they logically
    depend on this step (with clear instructions about the scope of *this*
    step).

  Each task must have:
  - A single, concrete goal
  - Clear, unambiguous definition of scope
  - Clear acceptance criteria
  - A detailed description of the change to be made, including any relevant code snippets, examples, and file paths
  - An "anchor" that describes the location in unambiguous terms (note that line numbers change across tasks, so anchors must reference components, syntax, or other relatively stable identifiers)

  It costs nothing to split tasks into smaller steps.
  Ultimately, the best experience for the user is for your plan to succeed and for the resulting code to be usable and correct.
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
  defp plan(state)

  defp plan(%{error: :invalid_response_format} = state) do
    state
    |> do_planning("""
    #{@plan_prompt}
    -----
    Your previous response was not in the correct format.
    Pay special attention to required fields and data types.
    Please adhere to the specified JSON schema.
    Try your response again, ensuring it matches the required format.
    """)
  end

  defp plan(%{error: nil} = state) do
    state
    |> do_planning(@plan_prompt)
    |> case do
      %{error: nil} = state -> state
      state -> plan(state)
    end
  end

  defp plan(state), do: state

  @spec do_planning(t, binary) :: t
  defp do_planning(state, prompt) do
    UI.report_from(state.agent.name, "Planning steps to reach desired state", state.request)

    state
    |> Common.get_completion(prompt, @plan_response_format)
    |> case do
      # No upstream errors
      # No upstream errors
      %{error: nil, response: response} ->
        case Jason.decode(response, keys: :atoms) do
          {:error, reason} ->
            UI.report_from(
              state.agent.name,
              "Planning failed",
              "JSON decode error: #{inspect(reason)}\n\n#{state.response}"
            )

            %{state | error: reason}

          {:ok, %{error: error}} ->
            UI.report_from(
              state.agent.name,
              "Planning failed",
              "#{inspect(error)}\n\n#{state.response}"
            )

            %{state | error: error}

          {:ok, %{steps: steps}} ->
            list_id = Services.Task.start_list()
            state = Common.put_state(state, :list_id, list_id)
            Common.add_tasks(list_id, steps)
            state

          _ ->
            UI.debug("Silly LLM!", """
            Invalid response format from planning step:

            #{response}

            """)

            %{state | error: :invalid_response_format}
        end

      # Upstream error
      state ->
        UI.report_from(
          state.agent.name,
          "Planning failed",
          "#{inspect(state.error)}\n\n#{state.response || "<no response>"}"
        )

        state
    end
  end
end

defmodule AI.Agent.Code.TaskImplementor do
  alias AI.Agent.Code.Common

  @type t :: Common.t()

  @model AI.Model.coding()

  @prompt """
  Before implementing, check for README.md, CLAUDE.md, and AGENTS.md in the project root and current directory.
  Use the file_contents_tool to read each. If both project and CWD versions exist, prefer the CWD file for local context.
  You are the Code Task Implementor, an AI agent within a larger system.
  Your role is to perform implementation tasks as directed by the Coordinating Agent.

  #{AI.Agent.Code.Common.coder_values_prompt()}

  # Procedure
  You will be given tasks to implement, one at a time, along with the overall requirements for the project.
  You will be asked to implement each task, in order, one at a time.
  Implement the current task (ONLY):
  - Use the `file_edit_tool` to make changes to the codebase.
  - Do not make any changes outside the scope of what was explicitly requested.
  - Ensure that your changes are well-documented and follow the project's coding standards.
  - Do not leave comments explaining what you did or the process you followed.
  - Comments should document the business workflow or concretely explain why a particular approach was taken.
  - Errors should be handled gracefully, but dovetail into existing patterns.
  - If you believe this implementation step should trigger a QA checkpoint, include an optional `checkpoint` boolean field set to true in your JSON output. Otherwise omit it or set it to false.

  # Checkpoint Heuristics
  Suggest a checkpoint ONLY when:
  - You introduced or modified cross-module interfaces, public APIs, or multi-file wiring, OR
  - A compilation step is likely to fail without additional steps, OR
  - You completed a self-contained unit that should compile and pass format/lint.
  Do NOT suggest checkpoints on purely local, single-file edits unless they change externally visible boundaries.

  If at any time you identify critical issues or unintended consequences, report them as `followUpTasks` that must be investigated.
  If at any time you determine that the change has unmet dependencies (e.g. using a function that does not yet exist), report them as `followUpTasks` that must be investigated, and respond with an `error` report detailing the issue.

  Use the `notify_tool` regularly to convey your reasoning, findings, and progress.
  """

  @response_format %{
    type: "json_schema",
    json_schema: %{
      name: "implementation_result",
      description: """
      A JSON object describing the outcome of the implementation task.
      """,
      schema: %{
        type: "object",
        required: ["error", "outcome", "followUpTasks"],
        additionalProperties: false,
        properties: %{
          error: %{
            type: "string",
            description: """
            A short error message summarizing why the implementation failed.
            Use an empty string if the implementation was successful. The
            presence of an error message will halt implementation of future
            tasks, requiring the Coordinating Agent to investigate and address
            the issue(s) you document in `outcome` before proceeding.
            """
          },
          checkpoint: %{
            type: "boolean",
            description:
              "Optional flag: true if a QA checkpoint is suggested after this implementation step."
          },
          outcome: %{
            type: "string",
            description: """
            A short report on the outcome of the implementation task. Include a
            walk-through of the changes made, the reasoning behind decisions,
            and any relevant context that the Coordinating Agent should be
            aware of when reviewing the completed work.

            If `error` is set, instead provide a detailed explanation of the
            issue(s) encountered, including any relevant code snippets,
            examples, and file paths. This should be a comprehensive report
            that allows the Coordinating Agent to understand the problem and
            take appropriate action to resolve it in the next iteration of the
            design.
            """
          },
          followUpTasks: %{
            type: "array",
            items: %{
              type: "object",
              description: """
              A follow-up task that must be investigated by the Coordinating
              Agent before the next implementation task is completed. This
              field is *ignored* if `error` is set.
              """,
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

  # ----------------------------------------------------------------------------
  # Behaviour Implementation
  # ----------------------------------------------------------------------------
  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(%{
        agent: agent,
        task_list_id: task_list_id,
        requirements: requirements
      }) do
    tasks = Services.Task.as_string(task_list_id, true)

    request = """
    # Requirements
    #{requirements}

    # Implementation Steps
    #{tasks}

    # Instructions
    The Coordinating Agent has asked you to implement the above tasks.

    # Handling file editing problems
    The `file_edit_tool` creates a backup of each file it modifies in the same directory, with a `.bak` extension.
    In case of problems, you may revert changes by replacing the file with the latest .bak file.
    """

    tools = AI.Tools.with_rw_tools()

    agent
    |> Common.new(@model, tools, @prompt, request)
    |> Common.put_state(:task_list_id, task_list_id)
    |> Common.put_state(:requirements, requirements)
    |> implement()
    |> summarize()
    |> case do
      %{error: nil, response: summary} ->
        {:ok,
         """
         # Work Completed
         #{Services.Task.as_string(task_list_id, true)}

         # Report
         #{summary}
         """}

      %{error: error} ->
        {:error, error}
    end
  end

  # ----------------------------------------------------------------------------
  # Core Logic
  # ----------------------------------------------------------------------------
  defp implement(state, invalid_format? \\ false)

  defp implement(%{error: nil} = state, invalid_format?) do
    with {:ok, task_list_id} <- Common.get_state(state, :task_list_id),
         {:ok, task} <- Services.Task.peek_task(task_list_id) do
      UI.report_from(state.agent.name, "Working on a task", task.id)

      prompt = """
      Here are the details of your current task.

      # Ticket
      #{task.id}

      # Details
      #{task.data}

      # Instructions
      1. The project requirements are provided to give you context, but restrict your changes to what is explicitly requested in *this* ticket.
      2. Implement the task as described, following the coding standards and practices of the project.
      3. Use your tools to manually confirm your changes.
         Read the file to ensure your change was applied correctly.
         Verify the correct syntax, compilation, and formatting of the code, to the extent possible, given that the code may be in flux (e.g. calling a function that will be added in a future step).
         Continue editing the file until you are satisfied that your change is correct.
         Your job is not complete until the task is fully implemented and tested.
      """

      prompt =
        if invalid_format? do
          """
          #{prompt}
          -----
          Your previous response was not in the correct format.
          Pay special attention to required fields and data types.
          Please adhere to the specified JSON schema.
          Try your response again, ensuring it matches the required format.
          """
        else
          prompt
        end

      state
      |> Common.get_completion(prompt, @response_format)
      |> case do
        %{error: nil, response: response} = state ->
          case Jason.decode(response, keys: :atoms) do
            {:ok, %{error: "", outcome: outcome, followUpTasks: new_tasks} = decoded} ->
              cp? = Map.get(decoded, :checkpoint, false)
              state = Common.put_state(state, :checkpoint?, cp?)

              if cp? do
                UI.report_from(
                  state.agent.name,
                  "Checkpoint suggested",
                  "A QA checkpoint has been suggested for task #{task.id}."
                )
              end

              Common.report_task_outcome(state, task, "", outcome, new_tasks)
              Services.Task.complete_task(task_list_id, task.id, outcome)
              Common.add_tasks(task_list_id, new_tasks)
              Common.report_task_stack(state)
              implement(state)

            {:ok, %{error: error, outcome: outcome, followUpTasks: new_tasks}} ->
              Common.report_task_outcome(state, task, error, outcome, new_tasks)
              Services.Task.fail_task(task_list_id, task.id, error)
              %{state | error: error}

            {:error, reason} ->
              UI.report_from(
                state.agent.name,
                "Invalid task response",
                "JSON decode error: #{inspect(reason)}\n\n#{state.response}"
              )

              %{state | error: reason}

            _ ->
              implement(state, true)
          end

        state ->
          UI.report_from(
            state.agent.name,
            "Model error",
            "task=#{task.id}\n#{inspect(state.error)}\n\n#{state.response || "<no response>"}"
          )

          state
      end
    else
      {:error, :empty} ->
        UI.report_from(
          state.agent.name,
          "No tasks remaining",
          "No more tasks in the current task list."
        )

        state

      {:error, :not_found} ->
        UI.warn("Task list not found for agent #{state.agent.name}")
        %{state | error: :task_list_not_found}
    end
  end

  defp implement(state, _), do: state

  # ----------------------------------------------------------------------------
  # Summary
  # ----------------------------------------------------------------------------
  @summary_prompt """
  The work is complete, for better or worse.
  Now you must report to the Coordinating Agent on the outcome of the project.
  Produce a concise report outlining the work done, changes made, and problems encountered.
  """

  defp summarize(state) do
    state = Common.get_completion(state, @summary_prompt, nil, true)

    cp? =
      case Common.get_state(state, :checkpoint?) do
        {:ok, true} -> true
        _ -> false
      end

    if cp? and is_binary(state.response) do
      # Append a conservative, machine-readable marker
      %{
        state
        | response: String.trim_trailing(state.response) <> "\n\n[checkpoint_suggested:true]\n"
      }
    else
      state
    end
  end
end

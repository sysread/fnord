defmodule AI.Agent.Code.TaskImplementor do
  alias AI.Agent.Code.Common

  @type t :: Common.t()

  @model AI.Model.reasoning(:high)

  @prompt """
  You are the Code Task Implementor, an AI agent within a larger system.
  Your role is to perform implementation tasks as directed by the Coordinating Agent.

  #{AI.Agent.Code.Common.coder_values_prompt()}

  # Procedure
  You will be given a list of tasks to implement, along with the overall requirements for the project.
  You will be asked to implement each task, in order, one at a time.
  Implement the current task (ONLY):
  - Do not make any changes outside the scope of what was explicitly requested.
  - Ensure that your changes are well-documented and follow the project's coding standards.
  - Do not leave comments explaining what you did or the process you followed.
  - Comments should document the business workflow or concretely explain why a particular approach was taken.
  - Errors should be handled gracefully, but dovetail into existing patterns.
  If at any time you identify critical issues or unintended consequences, report them as `followUpTasks` that must be investigated.
  If at any time you determine that the change has unmet dependencies (e.g. using a function that does not yet exist), report them as `followUpTasks` that must be investigated, and respond with an `error` report detailing the issue.
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
  def get_response(%{task_list_id: task_list_id, requirements: requirements}) do
    tasks = TaskServer.as_string(task_list_id, true)

    request = """
    # Requirements
    #{requirements}

    # Implementation Steps
    #{tasks}

    # Instructions
    The Coordinating Agent has asked you to implement the above tasks.
    """

    tools =
      AI.Tools.all_tools()
      |> AI.Tools.with_rw_tools()

    Common.new(@model, tools, @prompt, request)
    |> Common.put_state(:task_list_id, task_list_id)
    |> Common.put_state(:requirements, requirements)
    |> implement()
    |> summarize()
    |> case do
      %{error: nil, response: summary} ->
        {:ok,
         """
         # Work Completed
         #{TaskServer.as_string(task_list_id, true)}

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

  defp implement(%{error: nil, name: name} = state, invalid_format?) do
    with {:ok, task_list_id} <- Common.get_state(state, :task_list_id),
         {:ok, task} <- TaskServer.peek_task(task_list_id) do
      UI.info("#{name} is working", task.id)

      task_prompt =
        if invalid_format? do
          """
          Your previous response was not in the correct format.
          Pay special attention to required fields and data types.
          Please adhere to the specified JSON schema.
          Try your response again, ensuring it matches the required format.
          """
        else
          """
          # Ticket
          #{task.id}

          # Details
          #{task.data}

          # Instructions
          The project requirements are provided to give you context, but restrict
          your changes to what is explicitly requested in *this* ticket.
          """
        end

      state
      |> Common.get_completion(task_prompt, @response_format)
      |> case do
        %{error: nil, response: response} = state ->
          response
          |> Jason.decode(keys: :atoms)
          |> case do
            {:ok, %{error: "", outcome: outcome, followUpTasks: new_tasks}} ->
              # Report the outcome to the user
              Common.report_task_outcome(task, "", outcome, new_tasks)

              # Mark the task as completed
              TaskServer.complete_task(task_list_id, task.id, outcome)

              # If there are follow-up tasks, toss them on the stack
              Common.add_follow_up_tasks(task_list_id, new_tasks)
              Common.report_task_stack(state)

              # Then, recurse to handle the next task.
              implement(state)

            {:ok, %{error: error, outcome: outcome, followUpTasks: new_tasks}} ->
              # Report the error to the user
              Common.report_task_outcome(task, error, outcome, new_tasks)

              # Mark the task as failed
              TaskServer.fail_task(task_list_id, task.id, error)

              # Return the state with the error
              %{state | error: error}

            {:error, reason} ->
              %{state | error: reason}

            _ ->
              implement(state, true)
          end

        state ->
          state
      end
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

  defp summarize(state), do: Common.get_completion(state, @summary_prompt, %{}, true)
end

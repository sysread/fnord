defmodule AI.Agent.Code.TaskImplementor do
  alias AI.Agent.Code.Common

  @type t :: Common.t()

  @model AI.Model.reasoning(:high)

  @prompt """
  You are the Code Task Implementor, an AI agent within a larger system.
  Your role is to perform implementation tasks as directed by the Coordinating Agent.

  #{AI.Agent.Code.Common.coder_values_prompt()}
  """

  # ----------------------------------------------------------------------------
  # Behaviour Implementation
  # ----------------------------------------------------------------------------
  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(%{task_list_id: task_list_id}) do
    tasks = TaskServer.as_string(task_list_id, true)

    request = """
    The Coordinating Agent has requested that you implement the following tasks:
    #{tasks}
    """

    Common.new(@model, AI.Tools.all_tools(:rw), @prompt, request)
    |> Common.put_state(:task_list_id, task_list_id)
    |> implement()
    |> verify()
    |> summarize()
    |> case do
      %{error: nil, response: summary} ->
        {:ok,
         """
         # Task Implementation Summary
         #{TaskServer.as_string(task_list_id, true)}

         # Report
         #{summary}
         """}

      %{error: error} ->
        {:error, error}
    end
  end

  # ----------------------------------------------------------------------------
  # Implement the requested changes
  # ----------------------------------------------------------------------------
  @implement_prompt """
  Implement the requested changes.
  Do not make any changes outside the scope of what was explicitly requested.
  Ensure that your changes are well-documented and follow the project's coding standards.
  Do not leave comments explaining what you did or the process you followed.
  Comments should document the business workflow or concretely explain why a particular approach was taken.
  Errors should be handled gracefully, but dovetail into existing patterns.
  If you identify critical issues or unintended consequences, report them as `followUpTasks` that must be investigated.
  If you determine that the change has unmet dependencies (e.g. using a function that does not yet exist), report them as `followUpTasks` that must be investigated, and respond with an `error` report detailing the issue.
  """

  @implementation_response_format %{
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

  defp implement(%{error: nil} = state) do
    with {:ok, task_list_id} <- Common.get_state(state, :task_list_id),
         {:ok, task} <- TaskServer.peek_task(task_list_id) do
      UI.debug("Implementing task", task.id)

      prompt = """
      #{@implement_prompt}
      -----
      Ticket: #{task.id}
      Details:

      #{task.detail}
      """

      state
      |> Common.get_completion(prompt, @implementation_response_format)
      |> case do
        %{error: nil, response: response} = state ->
          response
          |> Jason.decode()
          |> case do
            {:ok, %{"error" => "", "outcome" => outcome, "followUpTasks" => new_tasks}} ->
              # Report the outcome to the user
              report_task_outcome(task, "", outcome, new_tasks)

              # Mark the task as completed
              TaskServer.complete_task(task_list_id, task.id, outcome)

              # If there are follow-up tasks, toss them on the stack
              Enum.each(new_tasks, &TaskServer.push_task(task_list_id, &1.label, &1.detail))
              report_task_stack(state)

              # Then, recurse to handle the next task.
              implement(state)

            {:ok, %{"error" => error, "outcome" => outcome, "followUpTasks" => new_tasks}} ->
              # Report the error to the user
              report_task_outcome(task, error, outcome, new_tasks)

              # Mark the task as failed
              TaskServer.fail_task(task_list_id, task.id, error)

              # Return the state with the error
              %{state | error: error}

            {:error, reason} ->
              %{state | error: reason}
          end

        state ->
          state
      end
    end
  end

  defp implement(state), do: state

  # ----------------------------------------------------------------------------
  # QA the implementation
  # ----------------------------------------------------------------------------
  @qa_prompt """
  Review the implementation of the task and ensure that it meets the acceptance criteria.
  Use the tool calls at your disposal to verify that the implementation is correct.
  If you have tools that can run unit tests, use them to verify that the implementation works as expected.
  Note that you can perform temporary edits of the code to printf-debug, so long as you remove them before returning the result.
  If you have access to linters in this project, use them to ensure that the code adheres to the project's coding standards.
  If you have access to formatters, use them to ensure that the code is properly formatted.
  If you identify any bugs, report them as `followUpTasks` that must be resolved.
  If there are no tests for this change and there is no way to verify the implementation, report this as a `followUpTask` to be resolved.
  If you notice any tech debt left as part of the implementation, report it as a `followUpTask` to be resolved.
  """

  @qa_response_format %{
    type: "json_schema",
    json_schema: %{
      name: "qa_result",
      description: """
      A JSON object describing any issues identified during the QA process.
      """,
      schema: %{
        type: "object",
        required: ["followUpTasks"],
        additionalProperties: false,
        properties: %{
          followUpTasks: %{
            type: "array",
            items: %{
              type: "object",
              description: """
              A follow-up task that must be investigated by the Coordinating
              Agent before the next implementation task is completed. This
              field is *ignored* if `error` is set. If no issues are found,
              this should be an empty array.
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

  defp verify(%{error: nil} = state) do
    with {:ok, task_list_id} <- Common.get_state(state, :task_list_id) do
      prompt = """
      #{@qa_prompt}
      -----
      Here are the tasks which have been implemented. Please test them
      thoroughly to confirm that everything is hooked up as expected and is
      functioning as intended.

      #{TaskServer.as_string(task_list_id, true)}
      """

      state
      |> Common.get_completion(prompt, @qa_response_format)
      |> case do
        %{error: nil, response: response} = state ->
          response
          |> Jason.decode()
          |> case do
            {:ok, %{"followUpTasks" => []}} ->
              # Report the outcome of QA
              UI.debug("QA passed", """
              The implementation has passed QA.
              No follow-up tasks were identified.
              """)

              # All good, we're done!
              %{state | error: nil}

            {:ok, %{"followUpTasks" => new_tasks}} ->
              # Report the outcome of QA
              UI.debug("QA identified follow-up tasks", format_new_tasks(new_tasks))

              # Push the new tasks onto the stack
              Enum.each(new_tasks, &TaskServer.push_task(task_list_id, &1.label, &1.detail))
              report_task_stack(state)

              # Pass control back to `implement/1` to continue working
              implement(state)

            {:error, reason} ->
              %{state | error: reason}
          end

        state ->
          state
      end
    end
  end

  defp verify(state), do: state

  # ----------------------------------------------------------------------------
  # Summary
  # ----------------------------------------------------------------------------
  @summary_prompt """
  The work is complete, for better or worse.
  Now you must report to the Coordinating Agent on the outcome of the project.
  Produce a concise report outlining the work done, changes made, and problems encountered.
  """

  defp summarize(state) do
    Common.get_completion(state, @summary_prompt, %{}, true)
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------
  defp report_task_stack(state) do
    with {:ok, task_list_id} <- Common.get_state(state, :task_list_id) do
      UI.debug("Pending Work", TaskServer.as_string(task_list_id))
    end
  end

  defp format_new_tasks(new_tasks) do
    new_tasks
    |> Enum.map(&"- #{&1.label}")
    |> Enum.join()
    |> case do
      "" -> "No follow-up tasks were identified."
      tasks -> tasks
    end
  end

  defp report_task_outcome(task, "", outcome, follow_up_tasks) do
    UI.debug(
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

  defp report_task_outcome(task, error, outcome, follow_up_tasks) do
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

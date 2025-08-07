defmodule AI.Agent.Code.TaskValidator do
  alias AI.Agent.Code.Common

  # ----------------------------------------------------------------------------
  # Globals
  # ----------------------------------------------------------------------------
  @type t :: Common.t()

  @model AI.Model.reasoning(:high)

  @prompt """
  Review the implementation of the task and ensure that it meets the acceptance criteria.

  ## Investigate
  Use your tool calls to ensure that you understand the affected components and features.
  Identify ways that you can exercise the new code:
  - If it has good test coverage, run the tests.
  - If there is a way to compile/run the code directly, do so (e.g. a binary, makefile, docker-compose, etc.).
  - If there is a REPL or interactive console, that can be used to explore the new functionality.
  - If the project's language features an interpreter that can be used to execute code directly, use it to explore the new functionality.
  - You can use the `shell_tool` to run commands that are not covered directly by the tool_calls you have access to.
  Identify compilers, interpreters, linters, formatters, and other tools that can be leveraged to verify the completeness and correctness of the implementation.

  ## Validate
  Use the tool calls at your disposal to verify that the implementation is correct.
  If you have tools that can run unit tests, use them to verify that the implementation works as expected.
  Note that you can perform temporary edits of the code to printf-debug, **so long as you remove them before returning the result.**
  If you identify any bugs, report them as `followUpTasks` that must be resolved.
  If there are no tests for this change and there is no way to verify the implementation, report this as a `followUpTask` to be resolved.
  If you notice any tech debt left as part of the implementation, report it as a `followUpTask` to be resolved.
  If you identify a significant bug or issue that prevents you from completing verification, report it as a `followUpTask`.
  It will be addressed and you will be given the opportunity to re-verify once it is resolved.
  """

  @response_format %{
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

  # ----------------------------------------------------------------------------
  # Behaviour Implementation
  # ----------------------------------------------------------------------------
  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(%{
        task_list_id: task_list_id,
        requirements: requirements,
        change_summary: change_summary
      }) do
    tasks = TaskServer.as_string(task_list_id, true)

    request = """
    # Requirements
    The implementation steps below were taken to satisfy the following requirements:
    #{requirements}

    # Implementation Steps
    #{tasks}

    # Change Summary
    #{change_summary}
    """

    Common.new(@model, AI.Tools.all_tools(:rw), @prompt, request)
    |> Common.put_state(:task_list_id, task_list_id)
    |> Common.put_state(:requirements, requirements)
    |> verify()
    |> case do
      %{error: nil} -> {:ok, :validated}
      %{error: error} -> {:error, error}
    end
  end

  # ----------------------------------------------------------------------------
  # Core Logic
  # ----------------------------------------------------------------------------
  defp verify(%{error: nil} = state) do
    with {:ok, task_list_id} <- Common.get_state(state, :task_list_id) do
      UI.debug("Validating changes")

      prompt = "Please perform manual validation (QA) of the changes made to the code base."

      state
      |> Common.get_completion(prompt, @response_format)
      |> case do
        %{error: nil, response: response} = state ->
          response
          |> Jason.decode(keys: :atoms)
          |> case do
            {:ok, %{followUpTasks: []}} ->
              # Report the outcome of QA
              UI.debug("Validation complete", "No issues identified")

              # All good, we're done!
              %{state | error: nil}

            {:ok, %{followUpTasks: new_tasks}} ->
              # Report the outcome of QA
              UI.debug("Validation identified new issues", Common.format_new_tasks(new_tasks))

              # Push the new tasks onto the stack
              Common.add_follow_up_tasks(task_list_id, new_tasks)
              Common.report_task_stack(state)

              # Pass control back to the Coordinating Agent
              %{state | error: :issues_identified}

            {:error, reason} ->
              %{state | error: reason}
          end

        state ->
          state
      end
    end
  end

  defp verify(state), do: state
end

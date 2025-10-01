defmodule AI.Agent.Code.TaskValidator do
  alias AI.Agent.Code.Common

  # ----------------------------------------------------------------------------
  # Globals
  # ----------------------------------------------------------------------------
  @type t :: Common.t()

  @model AI.Model.coding()

  @prompt """
  Before validating, check for README.md, CLAUDE.md, and AGENTS.md in the project root and current directory.
  Use the file_contents_tool to read each. If both project and CWD versions exist, prefer the CWD file for local context.
  Review the implementation of the task and ensure that it meets the acceptance criteria.

  ## Investigate
  Use your tool calls to ensure that you understand the affected components and features.
  Identify ways that you can exercise the new code:
  - If it has good test coverage, run the tests.
  - If there is a way to compile/run the code directly, do so (e.g. a binary, makefile, docker-compose, etc.).
  - If there is a REPL or interactive console, that can be used to explore the new functionality.
  - If the project's language features an interpreter that can be used to execute code directly, use it to explore the new functionality.
  - You can use the `shell_tool` to run commands that are not covered directly by the tool_calls you have access to.
  - You can also use the `shell_tool` to test the behavior of the code in a more interactive way, such as evaluating commands with interpreted languages or running scripts.
  - It is perfectly acceptable to create test scripts or temporary files to explore the new functionality, so long as they are removed before returning the result.
  Identify compilers, interpreters, linters, formatters, and other tools that can be leveraged to verify the completeness and correctness of the implementation.
  Use the `notify_tool` regularly to convey your reasoning, findings, and progress.

  ## Validate
  Use the tool calls at your disposal to verify that the implementation is correct.
  If you have tools that can run unit tests, use them to verify that the implementation works as expected.
  Seek out tools that can be used to lint, format, or statically analyze the code to identify potential issues.
  Try to identify how unit tests can be run, and if possible, run them to verify that the implementation is correct.
  - If verification requires test-only branches in production code, report this as a follow-up task to refactor toward DI-based, production-boundary testing.
  Note that you can perform temporary edits of the code to printf-debug, **so long as you remove them before returning the result.**
  If you identify any bugs, report them as `followUpTasks` that must be resolved.
  If there are no tests for this change and there is no way to verify the implementation, report this as a `followUpTask` to be resolved.
  If you notice any tech debt left as part of the implementation, report it as a `followUpTask` to be resolved.
  If you identify a significant bug or issue that prevents you from completing verification, report it as a `followUpTask`.
  It will be addressed and you will be given the opportunity to re-verify once it is resolved.
  Use the `notify_tool` regularly to convey your reasoning, findings, and progress.
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
        agent: agent,
        task_list_id: task_list_id,
        requirements: requirements,
        change_summary: change_summary
      }) do
    tasks = Services.Task.as_string(task_list_id, true)

    request = """
    # Requirements
    The implementation steps below were taken to satisfy the following requirements:
    #{requirements}

    # Implementation Steps
    #{tasks}

    # Change Summary
    #{change_summary}
    """

    tools =
      AI.Tools.all_tools()
      |> AI.Tools.with_rw_tools()

    agent
    |> Common.new(@model, tools, @prompt, request)
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
  defp verify(state, invalid_format? \\ false)

  defp verify(%{error: nil} = state, invalid_format?) do
    with {:ok, task_list_id} <- Common.get_state(state, :task_list_id) do
      UI.report_from(state.agent.name, "Validating changes")

      prompt = "Please perform manual validation (QA) of the changes made to the code base."

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

      case Common.get_completion(state, prompt, @response_format) do
        %{error: nil, response: response} = state ->
          case Jason.decode(response, keys: :atoms) do
            {:ok, %{followUpTasks: []}} ->
              UI.report_from(state.agent.name, "Validation complete", "No issues identified")
              %{state | error: nil}

            {:ok, %{followUpTasks: new_tasks}} ->
              UI.report_from(
                state.agent.name,
                "The solution is incomplete. New tasks added to the stack.",
                Common.format_new_tasks(new_tasks)
              )

              Common.add_tasks(task_list_id, new_tasks)
              Common.report_task_stack(state)
              %{state | error: :issues_identified}

            {:error, reason} ->
              UI.report_from(
                state.agent.name,
                "Validation failed — invalid response format",
                "JSON decode error: #{inspect(reason)}\n\n#{state.response}"
              )

              %{state | error: reason}

            _ ->
              if invalid_format? do
                UI.report_from(
                  state.agent.name,
                  "Validation failed",
                  "Agent repeatedly returned invalid format"
                )

                %{state | error: :invalid_response_format}
              else
                verify(state, true)
              end
          end

        state ->
          UI.report_from(
            state.agent.name,
            "Validation failed",
            "#{inspect(state.error)}\n\n#{state.response || "<no response>"}"
          )

          state
      end
    else
      {:error, :not_found} -> state
    end
  end

  defp verify(state, _), do: state
end

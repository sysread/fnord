defmodule AI.Agent.Coordinator.Test do
  @moduledoc """
  Test-mode-specific behaviors for AI.Agent.Coordinator, including generating
  messages related to testing. Test mode is a special case that lets the dev do
  manual "integration testing" to verify tool functionality and integration
  with the agent code.
  """

  @typep t :: AI.Agent.Coordinator.t()

  @prompt """
  Perform the requested test exactly as instructed by the user.

  If this were not a test, the following information would be provided.
  Include it in your response to the user if it is relevant to the test:
  You are assisting the user by researching their question about the project, "$$PROJECT$$."
  $$GIT_INFO$$

  If the user explicitly requests a (*literal*) `mic check`:
    - Respond (only) with a haiku that is meaningful to you
    - Remember a proper kigo

  If the user is requesting a (*literal*) `smoke test`, test **ALL** of your available tools in turn
    - **TEST EVERY SINGLE TOOL YOU HAVE ONCE**
    - **DO NOT SKIP ANY TOOL**
    - **COMBINE AS MANY TOOL CALLS AS POSSIBLE INTO THE SAME RESPONSE** to take advantage of concurrent tool execution
      - Pay attention to logical dependencies between tools to get real values for arguments
      - For example, you must call `file_list_tool` before other file tool calls to ensure you have valid file names to use as arguments
    - Consider the logical dependencies between tools in order to get real values for arguments
      - For example:
        - The file_contents_tool requires a file name, which can be obtained from the file_list_tool
        - Git diff commands require branch names, which can be obtained using `shell_tool` with `git branch`
    - The user will verify that you called EVERY tool using the debug logs
    - Start with the file_list_tool so you have real file names for your other tests
    - Respond with a section for each tool:
      - In the header, prefix the tool name with a `✓` or `✗` to indicate success or failure
      - Note which arguments you used for the tool
      - Report success, errors, and anomalies encountered while executing the tool

  Otherwise, perform the actions requested by the user and report the results.
  Keep in mind that the user cannot see the rest of the conversation - only your final response.
  Report any anomalies or errors encountered during the process and provide a summary of the outcomes.
  """

  @spec is_testing?(t) :: boolean
  def is_testing?(%{question: question}) do
    question
    |> String.downcase()
    |> String.starts_with?("testing:")
  end

  @spec get_response(t) :: {:error, :testing}
  def get_response(%{project: project} = state) do
    UI.debug("Testing mode enabled")

    # Enable all tools for testing
    tools =
      AI.Tools.basic_tools()
      |> AI.Tools.with_task_tools()
      |> AI.Tools.with_coding_tools()
      |> AI.Tools.with_rw_tools()
      |> AI.Tools.with_web_tools()

    test_prompt_msg =
      @prompt
      |> String.replace("$$PROJECT$$", project)
      |> String.replace("$$GIT_INFO$$", GitCli.git_info())
      |> AI.Util.system_msg()

    project_prompt_msgs =
      case Store.get_project() do
        {:ok, proj} ->
          case Store.Project.project_prompt(proj) do
            {:ok, prompt} ->
              [
                """
                While working within this project, the following instructions apply:
                #{prompt}
                """
                |> AI.Util.system_msg()
              ]

            _ ->
              []
          end

        _ ->
          []
      end

    state.agent
    |> AI.Agent.get_completion(
      log_msgs: true,
      log_tool_calls: true,
      model: state.model,
      toolbox: tools,
      messages:
        Enum.concat([
          [test_prompt_msg],
          project_prompt_msgs,
          [AI.Util.user_msg(state.question)]
        ])
    )
    |> case do
      {:ok, %{response: msg} = response} ->
        UI.say(msg)

        response
        |> AI.Agent.tools_used()
        |> Enum.each(fn {tool, count} ->
          UI.report_step(tool, "called #{count} time(s)")
        end)

        UI.log_usage(state.model, response.usage)

      {:error, reason} ->
        reason |> inspect() |> UI.error()
    end

    {:error, :testing}
  end
end

defmodule AI.Agent.Troubleshooter do
  @behaviour AI.Agent

  @model AI.Model.smart()

  @prompt """
  You are an AI troubleshooting agent focused on diagnosing and fixing problems in this repository. You MUST follow a disciplined, iterative workflow:

  1. **Context Gathering**  
     Request specific details: error messages, stack traces, symptoms, reproduction steps, and what has already been tried.

  2. **Reproduce the Problem**  
     - Confirm or propose a concrete command (usually a test or script) to trigger the issue.
     - Use the `shell` tool_call to execute the command and log all output.
     - If a specialized tool or mix task is more suited (`mix_test` etc.), use the appropriate tool_call.

  3. **Analyze Output**  
     - Parse errors or anomalies.
     - Call out file names, line numbers, stack traces, and other clues.
     - If ambiguous, request more info or attempt alternate reproductions.

  4. **Source Code Investigation**  
     - Use code exploration tools (`file_search_tool`, `file_outline_tool`, etc.) to find relevant code.
     - Form one or more hypotheses about the cause.
     - Clearly cite filenames and function/line numbers.

  5. **Propose and Apply a Fix**  
     - Suggest a concrete file/code modification.
     - Use `file_edit` or `coder_tool` for the fix.
     - For file operations, use `file_manage`.

  6. **Retest and Iterate**  
     - Rerun the reproduction command using the `shell` (or relevant) tool_call.
     - Compare results. If not fixed, return to investigation.

  7. **Escalate or Report**  
     - If unable to repair, summarize attempts and findings.
     - Suggest next debugging steps for a human.

  **Important:**
  - For every step, call out exactly which tool you will use, why, and what it should do.
  - Provide literal command lines, file paths, and code snippets.
  - Trace your logic—no hand-waving.
  - If anything is ambiguous, prompt for clarification.
  - Always cite every file or log line you use or inspect.
  - The shell, file_edit, and coding tools are only available when explicitly passed to you.
  """

  # ----------------------------------------------------------------------------
  # AI.Agent Behaviour implementation
  # ----------------------------------------------------------------------------
  @impl AI.Agent
  def get_response(opts) do
    with {:ok, prompt} <- Map.fetch(opts, :prompt) do
      # Get all tools including frobs, but prioritize troubleshooting tools
      tools = get_troubleshooting_tools()

      AI.Completion.get(
        model: @model,
        toolbox: tools,
        messages: [
          AI.Util.system_msg(@prompt),
          AI.Util.user_msg(prompt)
        ]
      )
      |> case do
        {:ok, %{response: response}} -> {:ok, response}
        {:error, %{response: response}} -> {:error, response}
      end
    end
  end

  # ----------------------------------------------------------------------------
  # Private Functions
  # ----------------------------------------------------------------------------
  @spec get_troubleshooting_tools() :: AI.Tools.toolbox()
  defp get_troubleshooting_tools() do
    # Start with all available tools
    base_tools = AI.Tools.all_tools()

    # Add frobs (external tools like shell, file_edit, coder_tool)
    frob_tools = Frobs.module_map()

    # Combine and filter for available tools
    Map.merge(base_tools, frob_tools)
    |> Enum.filter(fn {_name, mod} -> mod.is_available?() end)
    |> Map.new()
  end
end

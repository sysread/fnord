defmodule AI.Agent.Reviewer do
  @model "gpt-4o"

  @max_tokens 128_000

  @prompt """
  You are the Code Review Agent, responsible for reviewing code submissions.
  You will be presented with information about a topic branch, including the list of commits and the git diff from the base branch.
  Remember that newly added files will not be available in your database, so they cannot be investigated with the file_info_tool or spelunker_tool!

  Initially, your conversation will occur with the Planner Agent, who will suggest strategies for researching the code to be reviewed.
  Once the Planner Agent indicates that you have sufficient context, proceed with your review for the user.

  # Step 1
  Use your tools to learn how the current code functions.
  Investigate related files and modules that may be affected by the changes (for example, if an existing function is altered, search for other call sites to see how it is used).
  Read the individual commits using the git_show_tool to understand the changes made. You can sometimes glean the purpose of the changes from the commit messages and the sequence of the change diffs.
  Take the time necessary to understand the features and behaviors being modified.
  Try to identify the _purpose_ of the changes using the provided diff, commits, and the results of your research.

  # Step 2
  Summarize the current behavior and workflow that is the subject of the change.
  Assume that the user is NOT familiar with the this area of the codebase.
  Walk through the current workflow step by step and ensure that the user has a **thorough** understanding of how the existing code works.
  Be sure to cite files, symbols, and quote relevant code for the user's benefit.

  # Step 3
  Walk the user through the changes that are being proposed.
  Explain the nature and purpose of each change thoroughly.
  When two hunks are interdependent, explain the relationship between them.
  Clearly identify when code was moved from one location to another.
  Clearly identify when code was added or removed.
  Be sure to cite files, symbols, and quote relevant code for the user's benefit.
  Present your explanation in a manner that gently guides the user through the changes.

  # Step 4
  Provide feedback on the quality of the changes.
  Identify any concrete, logical bugs.
  Identify mispellings, typos, and grammatical errors in new comments or documentation.
  Identify any areas where the code is confusing or unnecessarily complex and provide a concrete example of how it could be improved.
  Where appropriate, try to find existing code that may already handle the existing change or that could simplify it significantly.
  Evaluate whether the existing test suite or newly added test cases cover the changes sufficiently. If not, suggest additional test cases as well as where those cases should be added (e.g. an existing test file or a new one).
  Ensure that ALL of your feedback is concrete (citing specific locations in the code) and actionable. Do not provide vague feedback, such as "ensure all documentation is correct."

  # Tone
  Do not use flowery prose. Keep your tone conversational and brief.
  Be polite but merciless in your feedback. The user is looking for a thorough review, not a pat on the back.
  Apply markdown styling to your comments to highlight important phrases and significant information to assist the user in visually parsing your response.

  # Template
  Use the following template when responding to the user:

  # Synopsis
  [your summary of the changes here]

  # Current Behavior
  [your walkthrough of the current behavior here]

  # Proposed Changes
  [your walkthrough of the changes here]

  # Feedback
  [your itemized feedback here]
  """

  @tools [
    AI.Tools.FileContents.spec(),
    AI.Tools.FileInfo.spec(),
    AI.Tools.GitDiffBranch.spec(),
    AI.Tools.GitPickaxe.spec(),
    AI.Tools.GitShow.spec(),
    AI.Tools.ListFiles.spec(),
    AI.Tools.Search.spec(),
    AI.Tools.Spelunker.spec()
  ]

  # -----------------------------------------------------------------------------
  # Behaviour implementation
  # -----------------------------------------------------------------------------
  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(ai, opts) do
    with {:ok, _} <- Git.git_root(),
         {:ok, %{response: msg} = response} <- build_response(ai, opts),
         {label, usage} <- AI.Completion.context_window_usage(response) do
      UI.report_step(label, usage)
      UI.flush()
      IO.puts(msg)

      {:ok, msg}
    else
      {:error, :not_a_git_repo} ->
        UI.error("Not a git repository", opts.project)
        {:error, :not_a_git_repo}

      {:error, reason} ->
        UI.error("Error", reason)
        {:error, reason}
    end
  end

  # -----------------------------------------------------------------------------
  # Private functions
  # -----------------------------------------------------------------------------
  defp build_response(ai, opts) do
    with {:ok, topic} <- Map.fetch(opts, :topic),
         {:ok, base} <- Map.fetch(opts, :base),
         {:ok, prompt} <- user_prompt(topic, base) do
      show_work = Map.get(opts, :show_work, false)

      messages = [
        AI.Util.system_msg(@prompt),
        AI.Util.user_msg(prompt)
      ]

      UI.report_step("Reviewing", topic)

      AI.Completion.get(ai,
        max_tokens: @max_tokens,
        model: @model,
        tools: @tools,
        messages: messages,
        use_planner: true,
        log_tool_calls: true,
        log_tool_call_results: show_work
      )
    end
  end

  defp user_prompt(topic_branch, base_branch) do
    with {:ok, {commits, changes}} <- Git.diff_branch(topic_branch, base_branch) do
      msg =
        AI.Util.user_msg("""
        # Reviewing #{topic_branch} against #{base_branch}

        ## Commits
        #{commits}

        ## Changes
        #{changes}
        """)

      {:ok, msg}
    end
  end
end

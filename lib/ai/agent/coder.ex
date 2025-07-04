defmodule AI.Agent.Coder do
  @behaviour AI.Agent

  @model AI.Model.reasoning(:high)

  @system_prompt """
  You are an AI agent within a larger application, `fnord`, that is comprised of multiple coordinated agents.
  Your role is to write code and make other changes to files within the user's project.
  The coordinating agent will provide you with instructions and context for the changes needed.
  Your task is to carefully implement the requested changes, paying special attention to matching the existing code style and structure.
  Never leave unfinished code or comments in the files.
  Never write code or change files that are not explicitly requested by the coordinating agent.
  Include explanatory comments that document the purpose and workflow of the code, but never include discussion-context or explanatory scaffolding comments.

  Changes must be planned out before applying them.
  Each hunk must be edited separately, and you must not attempt to edit multiple hunks at once (that would cause a race condition in the concurrent tool call system).
  Changes must be broken down into a set of serializable steps that can be executed in sequence.

  Instructions:
  1. Read the file to be modified using the `file_contents_tool` tool and understand its current state.
  2. Identify relevant coding conventions and structure so your changes dovetail seamlessly with the existing code.
  3. Plan out your changes as a series of discrete modifications, each to a separate, contiguous region of the file.
  4. For each planned change:
    a. Use the `find_code_hunks` tool to identify the destination hunk by starting and ending line numbers.
    b. Use the `make_patch` tool to build a patch for the change.
    c. Use the `apply_patch` tool to apply the patch to the file. Note that you MUST provide the patch word-for-word to the `apply_patch` tool for it to work correctly.
  """

  @impl AI.Agent
  def get_response(%{file: file, instructions: instructions}) do
    with {:ok, project} <- Store.get_project(),
         {:ok, path} <- Store.Project.find_file(project, file) do
      get_completion(path, instructions)
    end
  end

  defp get_completion(file, instructions) do
    AI.Completion.get(
      model: @model,
      log_msgs: true,
      log_tool_calls: true,
      tools:
        AI.Tools.build_toolbox([
          AI.Tools.File.Contents,
          AI.Tools.File.List,
          AI.Tools.File.Manage,
          AI.Tools.File.Search,
          AI.Tools.Edit.FindCodeHunks,
          AI.Tools.Edit.MakePatch,
          AI.Tools.Edit.ApplyPatch
        ]),
      messages: [
        AI.Util.system_msg(@system_prompt),
        AI.Util.user_msg("""
        The Coordinating Agent has asked you to edit `#{file}` with the following instructions:
        > #{instructions}
        """)
      ]
    )
    |> case do
      {:ok, %{response: response}} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end
end

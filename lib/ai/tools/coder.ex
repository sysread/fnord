defmodule AI.Tools.Coder do
  @behaviour AI.Tools

  @doc """
  This tool relies on line numbers within the file to identify ranges. If those
  numbers change between the time the range is identified and the time the
  changes are applied, the tool will fail to apply the changes correctly.
  """
  @impl AI.Tools
  def async?, do: false

  @impl AI.Tools
  def is_available?, do: AI.Tools.has_indexed_project()

  @impl AI.Tools
  def ui_note_on_request(%{"file" => file, "instructions" => instructions}) do
    {"Editing file #{file}", instructions}
  end

  @impl AI.Tools
  def ui_note_on_result(%{"file" => file, "instructions" => instructions}, result) do
    {"Changes applied to #{file}",
     """
     # Instructions
     #{instructions}

     # Result
     #{result}
     """}
  end

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "coder_tool",
        description: """
        Triggers an LLM agent to perform a coding task to a contiguous region within a single file in the project source root.
        The LLM has no access to the tool_calls you have available. It can ONLY edit files. YOU must provide all information and context required to perform the task.
        Instructions must include ALL relevant context; this agent has no access to the prior conversation.
        Instructions must include clear, unambiguous "anchors", identifying a *single* region of the file to edit.
        Examples:
        - "Add a new, private function at the end of the file (in a syntactically appropriate location) named `blarg`. The function accepts 2 positional arguments, ..."
        - "In the import list at the top of the file, remove the import for `foo.bar` and add an import for `baz.qux`."
        - "This file contains a mix of spaces and tabs. Convert all tabs to spaces, and ensure the indentation is consistent with 2 spaces per level."
        """,
        parameters: %{
          type: "object",
          required: ["file", "instructions"],
          properties: %{
            file: %{
              type: "string",
              description: "The path to the file to edit, relative to the project source root."
            },
            instructions: %{
              type: "string",
              description: "Clear, detailed instructions for the changes to make to the file."
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(args) do
    with {:ok, project} <- Store.get_project(),
         {:ok, file} <- AI.Tools.get_arg(args, "file"),
         {:ok, instructions} <- AI.Tools.get_arg(args, "instructions"),
         :ok <- validate_path(file, project.source_root),
         {:ok, {start_line, end_line}} <- identify_range(file, instructions),
         {:ok, replacement, preview} <- dry_run(file, instructions, start_line, end_line),
         :ok <- confirm_changes(file, instructions, preview) do
      {:ok, result} = apply_changes(file, start_line, end_line, replacement)
      UI.info("Changes applied to #{file}:#{start_line}-#{end_line}", result)
      {:ok, result}
    else
      {:error, :enoent} ->
        {:error,
         """
         FAILURE: The coder_tool was unable to apply the requested changes. No changes were made to the file.
         The requested file does not exist or is not a regular file.
         Please use the `list_files_tool` or one of the search tools to find the correct file path.
         """}

      {:error, reason} ->
        {:error,
         """

         FAILURE: The coder_tool was unable to apply the requested changes. No changes were made to the file.
         #{reason}
         """}
    end
  end

  defp validate_path(path, root) do
    cond do
      !Util.path_within_root?(path, root) -> {:error, "not within project root"}
      !File.exists?(path) -> {:error, :enoent}
      !File.regular?(path) -> {:error, :enoent}
      true -> :ok
    end
  end

  defp identify_range(file, instructions) do
    %{instructions: instructions, file: file}
    |> AI.Agent.Coder.RangeFinder.get_response()
    |> case do
      {:ok, {start_line, end_line}} ->
        UI.info("Hunk identified in #{file}", "Lines #{start_line}...#{end_line}")
        {:ok, {start_line, end_line}}

      {:identify_error, msg} ->
        UI.warn("Coding failed", """
        The agent was unable to identify a contiguous range of lines in the file based on the provided instructions.
        #{msg}
        """)

        {:error,
         """
         The agent was unable to identify a single, contiguous range of lines in the file based on the provided instructions:
         #{msg}
         """}

      other ->
        other
    end
  end

  defp dry_run(file, instructions, start_line, end_line) do
    %{file: file, instructions: instructions, start_line: start_line, end_line: end_line}
    |> AI.Agent.Coder.DryRun.get_response()
  end

  defp confirm_changes(file, instructions, preview) do
    %{file: file, instructions: instructions, preview: preview}
    |> AI.Agent.Coder.Reviewer.get_response()
    |> case do
      :ok ->
        UI.info("Reviewer approved changes", file)
        :ok

      {:confirm_error, error} ->
        UI.warn("Reviewer rejected changes to #{file}", error)

        {:error,
         """
         The code reviewing agent found an error in the requested change:
         #{error}
         """}

      other ->
        other
    end
  end

  defp apply_changes(file, start_line, end_line, replacement) do
    AI.Tools.File.Edit.call(%{
      "path" => file,
      "start_line" => start_line,
      "end_line" => end_line,
      "replacement" => replacement,
      "dry_run" => false,
      "context_lines" => 5
    })
  end
end

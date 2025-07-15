defmodule AI.Tools.Coder do
  @max_attempts 3

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
         {:ok, replacement, preview} <- dry_run_changes(file, instructions, start_line, end_line),
         :ok <- confirm_changes(file, instructions, preview) do
      {:ok, result} = apply_changes(file, start_line, end_line, replacement)
      UI.info("Changes applied to #{file}:#{start_line}-#{end_line}", result)
      {:ok, result}
    else
      {:identify_error, error} ->
        {:error,
         """
         FAILURE: The coder_tool was unable to apply the requested changes. No changes were made to the file.

         The agent was unable to identify a single, contiguous range of lines in the file based on the provided instructions:
         #{error}
         """}

      {:confirm_error, error, preview} ->
        {:error,
         """
         FAILURE: The coder_tool was unable to apply the requested changes. No changes were made to the file.

         The syntax checking agent found an error in the requested change:
         #{error}

         The change attempted was:
         #{preview}
         """}

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

  @spec validate_path(binary, binary) :: :ok | {:error, binary | :enoent}
  defp validate_path(path, root) do
    cond do
      !Util.path_within_root?(path, root) -> {:error, "not within project root"}
      !File.exists?(path) -> {:error, :enoent}
      !File.regular?(path) -> {:error, :enoent}
      true -> :ok
    end
  end

  @spec validate_range(binary, integer, integer) :: :ok | {:error, binary}
  defp validate_range(contents, start_line, end_line) do
    lines = num_lines(contents)

    cond do
      start_line < 1 ->
        {:error, "Start line must be greater than or equal to 1."}

      start_line > lines ->
        {:error, "Start line exceeds the number of lines in the file."}

      end_line < start_line ->
        {:error, "End line must be greater than or equal to start line."}

      lines > 0 && end_line > lines ->
        {:error, "End line exceeds the number of lines in the file."}

      true ->
        :ok
    end
  end

  @spec num_lines(binary) :: integer
  defp num_lines(str) do
    str
    |> String.split("\n", trim: false)
    |> length()
  end

  @spec identify_range(binary, binary, integer) ::
          {:ok, {integer, integer}}
          | {:error, binary}
          | {:error, :max_attempts_reached}
          | {:identify_error, binary}
  defp identify_range(file, instructions, attempt \\ 1)

  defp identify_range(_file, _instructions, attempt)
       when attempt > @max_attempts do
    {:error, :max_attempts_reached}
  end

  defp identify_range(file, instructions, attempt) do
    file_contents =
      file
      |> File.read!()
      |> Util.numbered_lines()

    system = """
    You are an AI coding assistant within a larger AI system.
    The Coordinating Agent asks you to identify a contiguous range of lines in a file based on the provided instructions for a coding task it is planning.
    Identify the *single*, contiguous range of lines in the file to be replaced, based on the instructions.
    Use your programming expertise to ensure that the range is appropriate to the intent of the instructions.
    For example, if asked to add a function at the end of the file, ensure the range would place the new function in a syntactically appropriate location.
    If the instructions are ambiguous or do not clearly point to a single range, respond with an error message that clearly explains the problem.

    # Response Format
    You MUST respond ONLY with a single JSON object with the following fields, based on whether you were able to identify a range:
    **Success:** `{"start_line": <start_line>, "end_line": <end_line>}`
    **Failure:** `{"error": "<error message>"}`

    Do not include any other text, comments, explanations, or markdown fences in your response.
    """

    user = """
    Please identify the range of lines in the file that should be replaced based on the following instructions.

    # Instructions
    #{instructions}

    # File: #{file}
    The file contents include 1-based line numbers at the start of each line, separated by a pipe (|).
    Constraints:
    - `start_line` <= `end_line`
    - `start_line` >= 1
    - `end_line` <= the number of lines in the file
    - if `start_line` == `end_line`, the range is a single line
    - The instructions will be applied to *fully* replace the identified range, so the range must cover the entire area to be replaced.
    ```
    #{file_contents}
    ```
    """

    AI.Completion.get(
      model: AI.Model.balanced(),
      messages: [
        AI.Util.system_msg(system),
        AI.Util.user_msg(user)
      ]
    )
    |> case do
      {:ok, %{response: response}} ->
        response
        |> Jason.decode()
        |> case do
          {:ok, %{"start_line" => start_line, "end_line" => end_line}} ->
            file_contents
            |> validate_range(start_line, end_line)
            |> case do
              :ok ->
                UI.info("Hunk identified in #{file}", "Lines #{start_line}...#{end_line}")
                {:ok, {start_line, end_line}}

              {:error, error} ->
                UI.warn("LLM identified range but it is invalid: #{error}")
                identify_range(file, instructions, attempt + 1)
            end

          {:ok, %{"error" => msg}} ->
            {:identify_error, msg}
        end

      {:error, reason} ->
        UI.warn("Error identifying range: #{inspect(reason)}")
        identify_range(file, instructions, attempt + 1)
    end
  end

  @spec dry_run_changes(binary, binary, integer, integer, integer) ::
          {:ok, binary, binary}
          | {:error, binary}
          | {:error, :max_attempts_reached}
  defp dry_run_changes(file, instructions, start_line, end_line, attempt \\ 1)

  defp dry_run_changes(_file, _instructions, _start_line, _end_line, attempt)
       when attempt > @max_attempts do
    {:error, :max_attempts_reached}
  end

  defp dry_run_changes(file, instructions, start_line, end_line, attempt) do
    file_contents =
      file
      |> File.read!()
      |> Util.numbered_lines()

    hunk =
      file_contents
      |> String.split("\n")
      |> Enum.slice(start_line - 1, end_line - start_line + 1)
      |> Enum.join("\n")

    system = """
    You are an AI coding assistant within a larger AI system.
    The Coordinating Agent asks you to apply changes to a file based on the provided instructions for a coding task.
    Your changes will COMPLETELY replace the hunk defined by the line range in the file.
    Respond with a block of code that will replace all other content within the hunk.
    Do not include any other text, comments, explanations, or markdown fences in your response.
    """

    user = """
    # File: #{file}
    The file contents include 1-based line numbers at the start of each line, separated by a pipe (|).
    IMPORTANT: Your response must NOT include any line numbers or their pipe (`|`) separators.
               Only output the raw file content for this region.
               If you include line numbers or `|`, that will break the file.
    ```
    #{file_contents}
    ```

    # Hunk: #{start_line}...#{end_line}
    This is the hunk from the file that will be replaced by your response.
    ```
    #{hunk}
    ```

    # Instructions
    Apply the following changes to the specified range of lines in the file.
    Make ONLY the changes explicitly requested by the Coordinating Agent.
    Perform NO other edits.

    #{instructions}
    """

    AI.Completion.get(
      model: AI.Model.balanced(),
      messages: [
        AI.Util.system_msg(system),
        AI.Util.user_msg(user)
      ]
    )
    |> case do
      {:ok, %{response: replacement}} ->
        # If the replacement is a single line, determine if it needs a trailing
        # newline, or if it was probably intended to be a deletion.
        replacement = normalize_single_line_replacement(replacement)

        AI.Tools.File.Edit.call(%{
          "path" => file,
          "start_line" => start_line,
          "end_line" => end_line,
          "replacement" => replacement,
          "dry_run" => true,
          "context_lines" => 5
        })
        |> case do
          {:ok, preview} ->
            UI.info("Patch prepared", """
            # #{file} | #{start_line}...#{end_line}

            ```
            #{replacement}
            ```
            """)

            {:ok, replacement, preview}

          {:error, reason} ->
            UI.warn("Error applying dry run changes: #{inspect(reason)}")
            dry_run_changes(file, instructions, start_line, end_line, attempt + 1)
        end

      {:error, reason} ->
        UI.warn("Error applying dry run changes: #{inspect(reason)}")
        dry_run_changes(file, instructions, start_line, end_line, attempt + 1)
    end
  end

  @spec confirm_changes(binary, binary, binary, integer) ::
          :ok
          | {:error, binary}
          | {:error, :max_attempts_reached}
          | {:confirm_error, binary, binary}
  defp confirm_changes(file, instructions, preview, attempt \\ 1)

  defp confirm_changes(_file, _instructions, _preview, attempt)
       when attempt > @max_attempts do
    {:error, :max_attempts_reached}
  end

  defp confirm_changes(file, instructions, preview, attempt) do
    file_contents =
      file
      |> File.read!()
      |> Util.numbered_lines()

    system = """
    You are an AI coding assistant within a larger AI system.
    The Coordinating Agent has asked you to confirm the changes made to a file based on the provided preview.
    You are required to confirm whether the changes are 1) correct, 2) syntactically valid, 3) true to the intent of the instructions.
    Use your programming knowledge to determine if the changes are syntactically correct.
    Use your experience as an engineer to determine if the changes are true to the intent of the instructions.
    If any significant issues are identified, respond with a clear error message explaining the problem.
    Bonus points if you can suggest improved instructions to avoid the issue on the next attempt.

    # Response Format
    Respond ONLY with one of the two following JSON objects:
    **Success:** `{"valid": true}`
    **Failure:** `{"valid": false, "error": "<clear explanation of the problem>"}`

    Do not include any other text, comments, explanations, or markdown fences in your response.
    """

    user = """
    Please confirm the changes made to the file based on the file contents and preview of the change.

    # Instructions
    #{instructions}

    # File: #{file}
    The file contents include 1-based line numbers at the start of each line, separated by a pipe (|).
    ```
    #{file_contents}
    ```

    # Preview of Change
    #{preview}
    """

    AI.Completion.get(
      model: AI.Model.balanced(),
      messages: [
        AI.Util.system_msg(system),
        AI.Util.user_msg(user)
      ]
    )
    |> case do
      {:ok, %{response: response}} ->
        response
        |> Jason.decode()
        |> case do
          {:ok, %{"valid" => true}} ->
            UI.info("Reviewer approved changes", file)
            :ok

          {:ok, %{"valid" => false, "error" => msg}} ->
            UI.info("Reviewer rejected changes to #{file}", msg)
            {:confirm_error, msg, preview}

          {:ok, %{"error" => error}} ->
            UI.info("Reviewer rejected changes to #{file}", error)
            {:confirm_error, error, preview}

          {:error, reason} ->
            UI.warn("Error decoding confirmation response: #{inspect(reason)}")
            confirm_changes(file, instructions, preview, attempt + 1)
        end

      {:error, reason} ->
        UI.warn("Error confirming changes: #{inspect(reason)}")
        confirm_changes(file, instructions, preview, attempt + 1)
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

  # Heuristic determination of whether a single line replacement should have a
  # trailing newline. Complicated by the fact that a single line replacement
  # could be a deletion (which we guess is the case for an empty string) or
  # just a fuck-up where it generated a single line patch but forgot the
  # newline.
  defp normalize_single_line_replacement(replacement) do
    cond do
      # Likely a *deletion* - no \n needed
      replacement == "" -> ""
      # Already has a trailing newline
      String.ends_with?(replacement, "\n") -> replacement
      # Single line without trailing newline - add one
      true -> replacement <> "\n"
    end
  end
end

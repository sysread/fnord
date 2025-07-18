defmodule AI.Agent.Coder.DryRun do
  @max_attempts 3

  @model AI.Model.reasoning(:high)

  @prompt """
  You are an AI coding assistant within a larger AI system.
  The Coordinating Agent asks you to apply changes to a file based on the provided instructions for a coding task.
  Your changes will COMPLETELY replace the hunk defined by the line range in the file.

  Note: The file contents include 1-based line numbers at the start of each line, separated by a pipe (|).
  IMPORTANT: Your response must NOT include any line numbers or their pipe (`|`) separators.
             Only output the raw file content for this region.
             If you include line numbers or `|`, that will break the file.

  Respond with a block of code that will replace all other content within the hunk.
  Do not include any other text, comments, explanations, or markdown fences in your response.
  """

  # ----------------------------------------------------------------------------
  # Behaviour Implementation
  # ----------------------------------------------------------------------------
  @behaviour AI.Agent

  @impl AI.Agent
  def get_response(opts) do
    with {:ok, instructions} <- Map.fetch(opts, :instructions),
         {:ok, file} <- Map.fetch(opts, :file),
         {:ok, start_line} <- Map.fetch(opts, :start_line),
         {:ok, end_line} <- Map.fetch(opts, :end_line) do
      dry_run_changes(file, instructions, start_line, end_line)
    else
      :error -> {:error, "Incorrect arguments passed to AI.Agent.Coder.DryRun."}
    end
  end

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------
  @spec dry_run_changes(binary, binary, integer, integer, integer) ::
          {:ok, binary, binary}
          | {:error, binary}
  defp dry_run_changes(file, instructions, start_line, end_line, attempt \\ 1)

  defp dry_run_changes(_, _, _, _, attempt) when attempt > @max_attempts do
    {:error, "Maximum attempts reached while trying to apply changes."}
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

    user = """
    # File: #{file}
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
      model: @model,
      messages: [
        AI.Util.system_msg(@prompt),
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

          {:error, _} ->
            dry_run_changes(file, instructions, start_line, end_line, attempt + 1)
        end

      {:error, _} ->
        dry_run_changes(file, instructions, start_line, end_line, attempt + 1)
    end
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

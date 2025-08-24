defmodule AI.Tools.File.Edit do
  @moduledoc """
  String-based code editing tool that uses exact and fuzzy string matching
  instead of line numbers. Handles whitespace normalization while preserving
  original formatting and indentation.
  """

  # ----------------------------------------------------------------------------
  # Types
  # ----------------------------------------------------------------------------
  @type edit_result :: %{
          file: binary,
          backup_file: binary,
          diff: binary
        }

  # ----------------------------------------------------------------------------
  # Behaviour Implementation
  # ----------------------------------------------------------------------------
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: true

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def ui_note_on_request(%{"file" => file}) do
    {"Preparing changes", file}
  end

  @impl AI.Tools
  def ui_note_on_result(%{"file" => file}, _result) do
    {"Changes applied", file}
  end

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "file_edit_tool",
        description: """
        Perform atomic, well-anchored edits to a single file.

        Use for:
        - One-off line or block replacements
        - Clear, unambiguous, file-local changes
        - Fast, low-risk operations

        NOT for system-wide, architectural, or ambiguous edits. Escalate to
        `coder_tool` for those!

        NOTE: This tool will FAIL if the file does not exist. Use the
        `shell_tool` to create the file first.
        """,
        parameters: %{
          type: "object",
          required: ["file", "changes"],
          additionalProperties: false,
          properties: %{
            file: %{
              type: "string",
              description: "Path (relative to project root) of the file to edit."
            },
            changes: %{
              type: "array",
              items: %{
                type: "object",
                description: """
                A list of changes to apply to the file.
                Steps are ordered logically, with each building on the previous.
                They will be applied in sequence.
                """,
                required: ["change"],
                additionalProperties: false,
                properties: %{
                  change: %{
                    type: "string",
                    description: """
                    Clear, specific instructions for the changes to make. The
                    instructions must be concise and unambiguous.

                    Clearly define the section(s) of the file to modify. Provide
                    unambiguous "anchors" that identify the exact location of the
                    change.

                    For example:
                    - "Immediately after the declaration of the `main` function, add the following code block: ..."
                    - "Replace the entire contents of the `calculate` function with: ..."
                    - "At the top of the file, insert the following imports, ensuring they are properly formatted and ordered: ..."
                    - "Add a new function at the end of the module named `blarg` with the following contents: ..."
                    """
                  }
                }
              }
            }
          }
        }
      }
    }
  end

  @spec call(map) :: {:ok, edit_result} | {:error, term}
  @impl AI.Tools
  def call(args) do
    with {:ok, file} <- AI.Tools.get_arg(args, "file"),
         {:ok, changes} <- read_changes(args),
         {:ok, result} <- do_edits_with_spinner(file, changes) do
      {:ok, result}
    end
  end

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------
  defp do_edits_with_spinner(file, changes) do
    start_spinner(file)

    try do
      do_edits(file, changes)
    rescue
      error ->
        stop_spinner(:error)

        {:error,
         """
         An error occurred while applying changes to the file, but it's not your fault.
         This is an internal application error.
         Please report it to the developers.

         Error message:
         #{Exception.message(error)}

         Stack trace:
         ```
         #{Exception.format_stacktrace(__STACKTRACE__)}
         ```
         """}
    end
  end

  defp start_spinner(file) do
    if UI.colorize?() do
      Owl.Spinner.start(
        id: :file_edit_tool,
        labels: [
          ok: "Changes ready for #{file}",
          error: "Failed to make changes to #{file}",
          processing: "Preparing changes for #{file}"
        ]
      )
    end
  end

  defp stop_spinner(resolution) do
    if UI.colorize?() do
      Owl.Spinner.stop(id: :file_edit_tool, resolution: resolution)
    end
  end

  defp do_edits(file, changes) do
    with {:ok, project} <- Store.get_project(),
         absolute_file <- Store.Project.expand_path(file, project),
         {:ok, contents} <- apply_changes(absolute_file, changes),
         {:ok, staged} <- stage_changes(contents),
         {:ok, diff} <- build_diff(absolute_file, staged),
         {:ok, :approved} <- confirm_edit(file, diff),
         {:ok, backup_file} <- backup_file(absolute_file),
         :ok <- commit_changes(absolute_file, staged) do
      {:ok,
       %{
         file: file,
         backup_file: backup_file,
         diff: diff
       }}
    end
  end

  defp apply_changes(file, changes) do
    AI.Agent.Code.Patcher.get_response(%{file: file, changes: changes})
  end

  defp stage_changes(contents) do
    with {:ok, temp} <- Briefly.create(),
         :ok <- File.write(temp, contents) do
      {:ok, temp}
    end
  end

  defp build_diff(file, staged) do
    System.cmd("diff", ["-u", "-L", "ORIGINAL", "-L", "MODIFIED", file, staged],
      stderr_to_stdout: true
    )
    |> case do
      {output, 1} -> {:ok, String.trim_trailing(output)}
      {_, 0} -> {:error, "no changes were made to the file"}
      {error, code} -> {:error, "diff exited #{code}: #{error}"}
    end
  end

  @spec confirm_edit(binary, binary) :: {:ok, :approved} | {:error, term}
  defp confirm_edit(file, diff) do
    stop_spinner(:ok)
    Services.Approvals.confirm({file, colorize_diff(diff)}, Services.Approvals.Edit)
  end

  @spec colorize_diff(binary) :: Owl.Data.t()
  def colorize_diff(diff) do
    diff
    |> String.split("\n")
    |> Enum.map(fn line ->
      cond do
        String.starts_with?(line, "+") -> Owl.Data.tag(line <> "\n", [:white, :green_background])
        String.starts_with?(line, "-") -> Owl.Data.tag(line <> "\n", [:white, :red_background])
        true -> line <> "\n"
      end
    end)
  end

  defp backup_file(file) do
    Services.BackupFile.create_backup(file)
  end

  defp commit_changes(file, staged) do
    File.cp(staged, file)
  end

  defp read_changes(opts) do
    with {:ok, changes} <- AI.Tools.get_arg(opts, "changes") do
      try do
        changes
        |> Enum.map(& &1["change"])
        |> Enum.map(&String.trim/1)
        |> then(&{:ok, &1})
      rescue
        _ in FunctionClauseError ->
          {:error,
           """
           Invalid changes format.
           Expected a list of objects with a "change" key.
           Each change is expected to be a string.
           """}
      end
    end
  end
end

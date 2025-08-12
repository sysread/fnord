defmodule AI.Tools.File.Edit do
  @moduledoc """
  String-based code editing tool that uses exact and fuzzy string matching
  instead of line numbers. Handles whitespace normalization while preserving
  original formatting and indentation.
  """

  # ----------------------------------------------------------------------------
  # Types
  # ----------------------------------------------------------------------------
  @type hunk :: Hunk.t()

  @type edit_result :: %{
          diff: binary,
          backup_file: binary,
          backup_files: [binary]
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
  def ui_note_on_request(%{"file" => file, "find" => find, "replacement" => replacement}) do
    {"Preparing file changes",
     """
     File: #{file}

     Replacing:
     ```
     #{find}
     ```

     With:
     ```
     #{replacement}
     ```
     """}
  end

  @impl AI.Tools
  def ui_note_on_result(%{"file" => file}, result) when is_binary(result) do
    case Jason.decode(result) do
      {:ok, %{"diff" => diff, "backup_file" => backup_file}} ->
        IO.write(:stderr, diff)
        {"File edited successfully", "#{file} (backup: #{Path.basename(backup_file)})"}

      _ ->
        IO.write(:stderr, result)
        {"File edited successfully", file}
    end
  end

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "file_edit_tool",
        description: """
        A tool for editing files by replacing specific sections of text. This
        tool uses an LLM agent to perform a "fuzzy match" against your
        selection criteria (`find`) within the contents of `file`. It then
        inserts the provided `replacement` text in place of the matched
        section, adjusting as necessary to preserve the original formatting and
        indentation.
        """,
        parameters: %{
          type: "object",
          required: ["file", "find", "replacement"],
          properties: %{
            file: %{
              type: "string",
              description: "Path (relative to project root) of the file to edit."
            },
            find: %{
              type: "string",
              description: """
              Describe the section to replace.
              Depending on the context, this could be:
              - The exact text to match
              - A description of the code to match with concrete anchors
              If the criteria is too ambiguous, the tool will fail with an error.

              Matching is done by an LLM agent and is resolved to complete
              lines of text in the source `file`. The ENTIRE matched section,
              starting from column 0 of the first line and ending at the final
              column of the last line, will be replaced IN FULL.
              """
            },
            replacement: %{
              type: "string",
              description: """
              The replacement text.
              This will replace the entire matched text.
              """
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
         {:ok, criteria} <- AI.Tools.get_arg(args, "find"),
         {:ok, replacement} <- AI.Tools.get_arg(args, "replacement"),
         {:ok, project} <- Store.get_project(),
         absolute_file <- Store.Project.expand_path(file, project),
         {:ok, hunk} <- find_hunk(file, criteria, replacement),
         {:ok, adjusted_replacement} <- adjust_replacement(file, hunk, replacement),
         {:ok, :approved} <- confirm_edit(file, hunk, adjusted_replacement),
         {:ok, backup_path} <- Services.BackupFile.create_backup(absolute_file),
         :ok <- apply_changes(hunk, adjusted_replacement) do
      diff = build_diff(hunk, adjusted_replacement)
      backup_files = Services.BackupFile.get_session_backups()

      result = %{
        diff: diff,
        backup_file: backup_path,
        backup_files: backup_files
      }

      {:ok, result}
    end
  end

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------
  @spec find_hunk(binary, binary, binary) ::
          {:ok, hunk}
          | {:error, term}
  defp find_hunk(file, criteria, replacement) do
    AI.Agent.Code.HunkFinder.get_response(%{
      file: file,
      criteria: criteria,
      replacement: replacement
    })
  end

  @spec adjust_replacement(binary, hunk, binary) ::
          {:ok, binary}
          | {:error, term}
  defp adjust_replacement(file, hunk, replacement) do
    AI.Agent.Code.PatchMaker.get_response(%{
      file: file,
      hunk: hunk,
      replacement: replacement
    })
  end

  defp apply_changes(hunk, replacement) do
    Hunk.replace_in_file(hunk, replacement)
  end

  @spec confirm_edit(binary, hunk, binary) ::
          {:ok, :approved}
          | {:error, term}
  defp confirm_edit(file, hunk, adjusted_replacement) do
    # Build approval bits for hierarchical approval - use file path components
    approval_bits = Path.split(file) |> Enum.reject(&(&1 == "."))

    # Create a preview diff to show the user what will change
    diff_preview = build_diff(hunk, adjusted_replacement)

    # Display the colorized diff separately before the approval prompt
    if UI.colorize?() and is_list(diff_preview) do
      IO.puts("\nDiff preview:")
      UI.say(diff_preview)
    end

    # Build a description of the change (without embedding the diff)
    description = """
    Edit file #{file}

    Lines #{hunk.start_line}-#{hunk.end_line}
    #{if not UI.colorize?(), do: "\n#{diff_preview}", else: ""}
    """

    # Use the approvals service with persistent: false (session-only approvals)
    Services.Approvals.confirm_command(
      description,
      approval_bits,
      "file_edit #{file}",
      tag: "file_edit",
      persistent: false
    )
  end

  defp build_diff(hunk, replacement) do
    colorize = UI.colorize?()

    diff_iodata =
      hunk.contents
      |> TextDiff.format(
        replacement,
        color: colorize,
        line_numbers: false,
        format: [
          gutter: [
            eq: "   ",
            del: " - ",
            ins: " + ",
            skip: "..."
          ]
        ]
      )

    # Don't convert to binary if colors are enabled - keep as iodata for ANSI formatting
    if colorize do
      diff_iodata
    else
      IO.iodata_to_binary(diff_iodata)
    end
  end
end

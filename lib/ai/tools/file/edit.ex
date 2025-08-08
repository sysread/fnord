defmodule AI.Tools.File.Edit do
  @moduledoc """
  String-based code editing tool that uses exact and fuzzy string matching
  instead of line numbers. Handles whitespace normalization while preserving
  original formatting and indentation.
  """

  # ----------------------------------------------------------------------------
  # Behaviour Implementation
  # ----------------------------------------------------------------------------
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: false

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def ui_note_on_request(_args), do: nil

  @impl AI.Tools
  def ui_note_on_result(_arg, _result), do: nil

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
          required: ["file", "replace", "with"],
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

  @impl AI.Tools
  def call(args) do
    with {:ok, file} <- AI.Tools.get_arg(args, "file"),
         {:ok, criteria} <- AI.Tools.get_arg(args, "find"),
         {:ok, replacement} <- AI.Tools.get_arg(args, "replacement"),
         {:ok, hunk} <- find_hunk(file, criteria, replacement),
         {:ok, adjusted_replacement} <- adjust_replacement(file, hunk, replacement),
         {:ok, updated_contents} <- update_file_contents(file, hunk, adjusted_replacement),
         :ok <- File.write(file, updated_contents) do
      {:ok, "done!"}
    end
  end

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------
  defp find_hunk(file, criteria, replacement) do
    AI.Agent.Code.HunkFinder.get_response(%{
      file: file,
      criteria: criteria,
      replacement: replacement
    })
  end

  defp adjust_replacement(file, hunk, replacement) do
    AI.Agent.Code.PatchMaker.get_response(%{
      file: file,
      start_line: hunk.start_line,
      end_line: hunk.end_line,
      replacement: replacement
    })
  end

  defp update_file_contents(file, hunk, replacement) do
    with {:ok, contents} <- File.read(file) do
      lines = String.split(contents, "\n")
      lines_before = lines |> Enum.take(hunk.start_line - 1)
      lines_after = lines |> Enum.drop(hunk.end_line)
      lines_within = String.split(replacement, "\n")

      {:ok, Enum.join(lines_before ++ lines_within ++ lines_after, "\n")}
    end
  end
end

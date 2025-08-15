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
              An empty string indicates that the entire matched section should be deleted.
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
         _ <- UI.spinner_start(id: :file_edit_tool, label: "Editing #{file}"),
         {:ok, project} <- Store.get_project(),
         absolute_file <- Store.Project.expand_path(file, project),
         {:ok, hunk} <- find_hunk(file, criteria, replacement),
         {:ok, adjusted_replacement} <- adjust_replacement(file, hunk, replacement),
         {:ok, hunk} <- Hunk.stage_changes(hunk, adjusted_replacement),
         {:ok, diff} <- Hunk.build_diff(hunk),
         {:ok, :approved} <- confirm_edit(hunk, diff),
         {:ok, _backup} <- Services.BackupFile.create_backup(absolute_file),
         {:ok, _hunk} <- Hunk.apply_staged_changes(hunk) do
      {:ok, diff}
    else
      other ->
        UI.spinner_stop(
          id: :file_edit_tool,
          resolution: :error,
          label: "Failed to edit file"
        )

        other
    end
  end

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------
  @spec find_hunk(binary, binary, binary) :: {:ok, hunk} | {:error, term}
  defp find_hunk(file, criteria, replacement) do
    UI.spinner_start(
      id: :hunk_finder,
      label: "Finding target hunk",
      frames: [
        ok: Owl.Data.tag("  ✔", :green),
        error: Owl.Data.tag("  ✖", :red),
        processing: ["  ⠋", "  ⠙", "  ⠹", "  ⠸", "  ⠼", "  ⠴", "  ⠦", "  ⠧", "  ⠇", "  ⠏"]
      ]
    )

    AI.Agent.Code.HunkFinder.get_response(%{
      file: file,
      criteria: criteria,
      replacement: replacement
    })
    |> case do
      {:ok, hunk} ->
        UI.spinner_stop(
          id: :hunk_finder,
          resolution: :ok,
          label: "Target hunk found"
        )

        {:ok, hunk}

      {:error, reason} ->
        UI.spinner_stop(
          id: :hunk_finder,
          resolution: :error,
          label: "Failed to find target hunk"
        )

        {:error, reason}
    end
  end

  @spec adjust_replacement(binary, hunk, binary) :: {:ok, binary} | {:error, term}
  defp adjust_replacement(file, hunk, replacement) do
    UI.spinner_start(
      id: :patch_maker,
      label: "Conforming replacement to target",
      frames: [
        ok: Owl.Data.tag("  ✔", :green),
        error: Owl.Data.tag("  ✖", :red),
        processing: ["  ⠋", "  ⠙", "  ⠹", "  ⠸", "  ⠼", "  ⠴", "  ⠦", "  ⠧", "  ⠇", "  ⠏"]
      ]
    )

    AI.Agent.Code.PatchMaker.get_response(%{
      file: file,
      hunk: hunk,
      replacement: replacement
    })
    |> case do
      {:ok, adjusted_replacement} ->
        UI.spinner_stop(
          id: :patch_maker,
          resolution: :ok,
          label: "Replacement adapted"
        )

        {:ok, adjusted_replacement}

      {:error, reason} ->
        UI.spinner_stop(
          id: :patch_maker,
          resolution: :error,
          label: "Failed to adapt replacement"
        )

        {:error, reason}
    end
  end

  @spec confirm_edit(hunk, binary) :: {:ok, :approved} | {:error, term}
  defp confirm_edit(hunk, diff) do
    UI.spinner_stop(
      id: :file_edit_tool,
      resolution: :ok,
      label: "Changes to #{hunk} prepared"
    )

    Services.Approvals.confirm(
      tag: "general",
      subject: "edit files",
      persistent: false,
      message: "Fnord wants to modify #{hunk}",
      detail: colorize_diff(diff)
    )
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
end

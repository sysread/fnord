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
  def async?, do: false

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def read_args(args) when is_map(args) do
    # Validate and default the create_if_missing flag
    case args["create_if_missing"] do
      nil ->
        {:ok, Map.put(args, "create_if_missing", false)}

      val when is_boolean(val) ->
        {:ok, args}

      _ ->
        {:error, "`create_if_missing` must be a boolean"}
    end
  end

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

        This is the best tool for simple changes that do not require extensive
        planning, coordination, or span many files.

        Use for:
        - One-off line or block replacements
        - Clear, unambiguous, file-local changes
        - Fast, low-risk operations

        Supports optional creation of the file when it does not exist by
        setting `create_if_missing: true`.
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
                description: """
                A list of changes to apply to the file.
                Steps are ordered logically, with each building on the previous.
                They will be applied in sequence.
                """,
                type: "object",
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
            },
            create_if_missing: %{
              type: "boolean",
              description: "If true, create the file (and parent dirs) if it doesn't exist.",
              default: false
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(raw_args) do
    # Parse and validate arguments, including create_if_missing
    with {:ok, args} <- read_args(raw_args),
         {:ok, file} <- AI.Tools.get_arg(args, "file"),
         {:ok, changes} <- read_changes(args) do
      # Determine whether to create file if missing
      create? = Map.get(args, "create_if_missing", false)

      with {:ok, result} <- do_edits(file, changes, create?) do
        {:ok, result}
      end
    end
  end

  # Parse and validate the list of change instructions
  @spec read_changes(map) :: {:ok, [String.t()]} | {:error, String.t()}
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
           Expected a list of objects with a \"change\" key.
           Each change is expected to be a string.
           """}
      end
    end
  end

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------
  @spec ensure_file(binary, boolean) :: :ok | {:error, String.t()}
  defp ensure_file(path, true) do
    # Create file and parent directories if missing
    unless File.exists?(path) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "")
    end

    :ok
  end

  defp ensure_file(path, false) do
    # Only ok if file already exists
    if File.exists?(path) do
      :ok
    else
      {:error, "File does not exist: #{path}"}
    end
  end

  # Main edit flow with optional file creation
  defp do_edits(file, changes, create_if_missing) do
    try do
      with {:ok, project} <- Store.get_project(),
           absolute_path <- Store.Project.expand_path(file, project),
           # Track original existence before optional creation
           orig_exists = File.exists?(absolute_path),
           :ok <- ensure_file(absolute_path, create_if_missing),
           {:ok, contents} <- apply_changes(absolute_path, changes),
           {:ok, diff, backup_file} <- stage_changes(absolute_path, contents, orig_exists) do
        {:ok,
         %{
           file: file,
           backup_file: backup_file,
           diff: diff
         }}
      end
    rescue
      error ->
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

  # Apply staged contents to disk, confirm, and optionally backup
  defp stage_changes(file, contents, orig_exists) do
    Util.Temp.with_tmp(contents, fn temp ->
      with {:ok, diff} <- build_diff(file, temp, orig_exists),
           {:ok, :approved} <- confirm_edit(file, diff),
           {:ok, backup_file} <- maybe_backup(file, orig_exists),
           :ok <- commit_changes(file, temp) do
        {:ok, diff, backup_file}
      end
    end)
  end

  defp apply_changes(file, changes) do
    AI.Agent.Code.Patcher
    |> AI.Agent.new()
    |> AI.Agent.get_response(%{file: file, changes: changes})
  end

  @spec build_diff(binary, binary, boolean) :: {:ok, binary} | {:error, String.t()}
  defp build_diff(file, staged, orig_exists) do
    # Use /dev/null as the original when creating a new file
    original = if orig_exists, do: file, else: "/dev/null"

    System.cmd("diff", ["-u", "-L", "ORIGINAL", "-L", "MODIFIED", original, staged],
      stderr_to_stdout: true
    )
    |> case do
      {output, 1} -> {:ok, String.trim_trailing(output)}
      {_, 0} -> {:error, "no changes were made to the file"}
      {error, code} -> {:error, "diff failed (#{code}): #{error}"}
    end
  end

  @spec confirm_edit(binary, binary) :: {:ok, :approved} | {:error, term}
  defp confirm_edit(file, diff) do
    Services.Approvals.confirm({file, colorize_diff(diff)}, :edit)
  end

  @spec colorize_diff(binary) :: Owl.Data.t()
  defp colorize_diff(diff) do
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

  @spec commit_changes(binary, binary) :: :ok | {:error, term}
  defp commit_changes(file, staged) do
    File.cp(staged, file)
  end

  @spec maybe_backup(binary, boolean) :: {:ok, binary | nil} | {:error, term}
  # Backup only if the original file existed prior to the edit
  defp maybe_backup(_file, false), do: {:ok, ""}
  defp maybe_backup(file, true), do: backup_file(file)
end

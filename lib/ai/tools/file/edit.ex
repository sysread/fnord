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
        Perform atomic, well-anchored edits to a single file using either exact
        string matching or AI-interpreted natural language instructions.

        This is the best tool for simple changes that do not require extensive
        planning, coordination, or span many files.

        **Two editing modes:**
        1. **Exact String Matching**: Provide old_string/new_string for precise,
           reliable replacements. Use when you know the exact text to change.
        2. **Natural Language**: Provide descriptive change instructions for the
           AI to interpret. Use when you need contextual understanding.

        Use for:
        - One-off line or block replacements
        - Clear, unambiguous, file-local changes
        - Fast, low-risk operations

        Supports optional creation of the file when it does not exist by
        setting `create_if_missing: true`.

        Best practices:
        - Use exact string matching for maximum reliability
        - Use natural language for contextual changes when exact strings are impractical
        - Prefer linear, atomic steps; avoid nested control flow in a single change
        - Split complex edits into multiple changes/tool calls
        - Keep diffs minimal and well-anchored with clear anchors
        """,
        parameters: %{
          type: "object",
          required: ["file"],
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
                  },
                  old_string: %{
                    type: "string",
                    description: """
                    Optional: Exact string to replace. When provided, this change will use
                    precise string matching instead of AI interpretation. The old_string must
                    match exactly (including whitespace) or the operation will fail.
                    Special case: Use empty string ("") with create_if_missing to create new files.
                    Cannot be used without new_string.
                    """
                  },
                  new_string: %{
                    type: "string",
                    description: """
                    Optional: Exact replacement string. Must be provided when old_string is used.
                    This will replace all occurrences of old_string unless replace_all is false.
                    For file creation, this becomes the entire file content.
                    """
                  },
                  replace_all: %{
                    type: "boolean",
                    description: """
                    Optional: When using exact string matching (old_string/new_string),
                    whether to replace all occurrences (true) or fail if old_string appears
                    multiple times (false). Defaults to false for safety.
                    """,
                    default: false
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
  @spec read_changes(map) :: {:ok, [change()]} | {:error, String.t()}
  defp read_changes(opts) do
    case Map.get(opts, "changes") do
      nil ->
        {:error, "Either 'changes' array or individual change parameters must be provided"}

      changes when is_list(changes) ->
        try do
          parsed_changes =
            changes
            |> Enum.map(&parse_change/1)
            |> Enum.map(fn
              {:ok, change} -> change
              {:error, error} -> throw({:parse_error, error})
            end)

          {:ok, parsed_changes}
        rescue
          _ in FunctionClauseError ->
            {:error,
             """
             Invalid changes format.
             Expected a list of objects with change instructions.
             """}
        catch
          {:parse_error, error} -> {:error, error}
        end

      _ ->
        {:error, "Changes must be an array"}
    end
  end

  # Define change types
  @type change :: %{
          type: :exact | :natural_language,
          instruction: String.t(),
          old_string: String.t() | nil,
          new_string: String.t() | nil,
          replace_all: boolean()
        }

  @spec parse_change(map) :: {:ok, change()} | {:error, String.t()}
  defp parse_change(change_map) when is_map(change_map) do
    instruction = Map.get(change_map, "change", "")
    old_string = Map.get(change_map, "old_string")
    new_string = Map.get(change_map, "new_string")
    replace_all = Map.get(change_map, "replace_all", false)

    cond do
      # Exact string matching mode
      old_string != nil and new_string != nil ->
        if is_binary(old_string) and is_binary(new_string) and is_boolean(replace_all) do
          {:ok,
           %{
             type: :exact,
             instruction: String.trim(instruction),
             old_string: old_string,
             new_string: new_string,
             replace_all: replace_all
           }}
        else
          {:error, "old_string and new_string must be strings, replace_all must be boolean"}
        end

      # Partial exact string matching (error case)
      old_string != nil or new_string != nil ->
        {:error, "Both old_string and new_string must be provided together"}

      # Natural language mode
      instruction != "" ->
        {:ok,
         %{
           type: :natural_language,
           instruction: String.trim(instruction),
           old_string: nil,
           new_string: nil,
           replace_all: false
         }}

      # No valid parameters
      true ->
        {:error, "Either provide 'change' instruction or 'old_string'/'new_string' pair"}
    end
  end

  defp parse_change(_), do: {:error, "Change must be an object"}

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------
  @spec ensure_file(binary, boolean) :: :ok | {:error, String.t()}
  defp ensure_file(path, true) do
    # Ensure parent directories exist, but do not pre-create the file itself
    unless File.exists?(path) do
      File.mkdir_p!(Path.dirname(path))
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
  @spec do_edits(binary, [change()], boolean) :: {:ok, edit_result} | {:error, String.t()}
  defp do_edits(file, changes, create_if_missing) do
    try do
      with {:ok, project} <- Store.get_project(),
           absolute_path <- Store.Project.expand_path(file, project),
           {orig_exists, orig_text} = read_file(absolute_path),
           base_hash = :crypto.hash(:sha256, orig_text),
           :ok <- ensure_file(absolute_path, create_if_missing),
           {:ok, contents} <- apply_all_changes(absolute_path, orig_text, changes) do
        if contents == orig_text do
          {:error, "no changes were made to the file"}
        else
          with {:ok, diff, backup_file} <-
                 stage_changes(absolute_path, contents, orig_exists, base_hash) do
            {:ok, %{file: file, diff: diff, backup_file: backup_file}}
          end
        end
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

  # Apply staged contents to disk, confirm, optionally backup, and verify no mid-flight changes
  @spec stage_changes(binary, binary, boolean, binary) ::
          {:ok, binary, binary} | {:error, String.t()}
  defp stage_changes(file, contents, orig_exists, base_hash) do
    Util.Temp.with_tmp(contents, fn temp ->
      with {:ok, diff} <- build_diff(file, temp, orig_exists),
           {:ok, :approved} <- confirm_edit(file, diff),
           {:ok, backup_file} <- maybe_backup(file, orig_exists),
           {:ok, _} <- verify_no_race(file, base_hash, orig_exists),
           :ok <- commit_changes(file, temp) do
        {:ok, diff, backup_file}
      end
    end)
  end

  # Apply all changes sequentially, handling both exact and natural language changes
  @spec apply_all_changes(binary, binary, [change()]) :: {:ok, binary} | {:error, String.t()}
  defp apply_all_changes(_file, contents, []), do: {:ok, contents}

  defp apply_all_changes(file, contents, [change | remaining]) do
    # Pre-validate natural language changes
    with :ok <- validate_change(change, contents),
         {:ok, new_contents} <- apply_single_change(file, contents, change) do
      apply_all_changes(file, new_contents, remaining)
    else
      {:error, reason} -> {:error, format_change_error(change, reason)}
    end
  end

  # Pre-validation for changes to catch common issues early
  @spec validate_change(change(), binary) :: :ok | {:error, String.t()}
  defp validate_change(%{type: :exact, old_string: old}, contents) when byte_size(old) == 0 do
    # Allow empty old_string only when creating a new file (empty contents)
    if byte_size(contents) == 0 do
      :ok
    else
      {:error, "old_string cannot be empty when editing existing content"}
    end
  end

  defp validate_change(%{type: :natural_language, instruction: instruction}, _contents) do
    cond do
      String.length(String.trim(instruction)) < 10 ->
        {:error,
         "Instruction too vague. Please provide more specific details about what to change and where."}

      not (String.contains?(instruction, [
             "after",
             "before",
             "at the",
             "in the",
             "replace",
             "add",
             "remove",
             "function",
             "line"
           ]) or
               Regex.match?(~r/\d+/, instruction)) ->
        {:error,
         "Instruction lacks clear location anchors. Consider specifying line numbers, function names, or relative positions."}

      true ->
        :ok
    end
  end

  defp validate_change(_change, _contents), do: :ok

  # Apply a single change based on its type
  @spec apply_single_change(binary, binary, change()) :: {:ok, binary} | {:error, String.t()}
  defp apply_single_change(_file, contents, %{type: :exact} = change) do
    apply_exact_change(contents, change)
  end

  defp apply_single_change(file, contents, %{type: :natural_language} = change) do
    apply_natural_language_change(file, contents, change.instruction)
  end

  # Handle exact string replacement
  @spec apply_exact_change(binary, change()) :: {:ok, binary} | {:error, String.t()}
  defp apply_exact_change(contents, %{old_string: old, new_string: new, replace_all: replace_all}) do
    cond do
      # File creation case: empty old_string with empty contents
      byte_size(old) == 0 and byte_size(contents) == 0 ->
        {:ok, new}

      # Empty old_string with non-empty contents (invalid)
      byte_size(old) == 0 ->
        {:error, "old_string cannot be empty when editing existing content"}

      # Normal replacement cases
      not String.contains?(contents, old) ->
        {:error, "String not found in file: #{inspect(old)}"}

      replace_all ->
        # Replace all occurrences
        {:ok, String.replace(contents, old, new)}

      true ->
        # Check for multiple occurrences when replace_all is false
        parts = String.split(contents, old)

        case parts do
          [_before, _after] ->
            # Exactly one occurrence
            {:ok, String.replace(contents, old, new)}

          _ ->
            # Multiple occurrences
            count = length(parts) - 1

            {:error,
             "String appears #{count} times in file. Set replace_all: true to replace all occurrences"}
        end
    end
  end

  # Handle natural language changes using the existing patcher
  @spec apply_natural_language_change(binary, binary, String.t()) ::
          {:ok, binary} | {:error, String.t()}
  defp apply_natural_language_change(file, _contents, instruction) do
    AI.Agent.Code.Patcher
    |> AI.Agent.new()
    |> AI.Agent.get_response(%{file: file, changes: [instruction]})
  end

  # Format error messages with context about which change failed
  @spec format_change_error(change(), String.t()) :: String.t()
  defp format_change_error(%{type: :exact, old_string: old}, reason) do
    """
    Exact string replacement failed:
    Searching for: #{inspect(old)}
    Error: #{reason}

    Suggestion: Verify the exact string exists in the file, including all whitespace and capitalization.
    """
  end

  defp format_change_error(%{type: :natural_language, instruction: instruction}, reason) do
    """
    Natural language instruction failed:
    Instruction: "#{instruction}"
    Error: #{reason}

    Suggestions:
    - Try using exact string replacement (old_string/new_string) for more reliable results
    - Make the instruction more specific with clear anchors (line numbers, function names, etc.)
    - Break complex changes into smaller, more specific steps
    """
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
    # Perform atomic write: copy staged content to a temp file, then rename over target
    dir = Path.dirname(file)
    tmp = Path.join(dir, ".#{Path.basename(file)}.tmp")

    case File.cp(staged, tmp) do
      :ok ->
        case File.rename(tmp, file) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec verify_no_race(binary, binary, boolean) :: {:ok, :ok} | {:error, String.t()}
  defp verify_no_race(_, _, false) do
    {:ok, :skipped}
  end

  defp verify_no_race(path, base_hash, true) do
    # Read current contents and compare hash to detect concurrent modifications
    current = File.read!(path)
    current_hash = :crypto.hash(:sha256, current)

    if current_hash == base_hash do
      {:ok, :ok}
    else
      {:error, "File changed on disk during edit; aborting"}
    end
  end

  @spec maybe_backup(binary, boolean) :: {:ok, binary | nil} | {:error, term}
  # Backup only if the original file existed prior to the edit
  defp maybe_backup(_file, false), do: {:ok, ""}
  defp maybe_backup(file, true), do: backup_file(file)

  defp read_file(abs_path) do
    abs_path
    |> File.exists?()
    |> case do
      true -> {true, File.read!(abs_path)}
      false -> {false, ""}
    end
  end
end

defmodule AI.Tools.File.Edit do
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
    with {:ok, args} <- read_create_if_missing(args),
         {:ok, args} <- AI.Tools.File.Edit.OMFG.normalize_agent_chaos(args) do
      {:ok, args}
    end
  end

  defp read_create_if_missing(args) do
    # Validate and default the create_if_missing flag
    case args["create_if_missing"] do
      true -> {:ok, args}
      false -> {:ok, args}
      nil -> {:ok, Map.put(args, "create_if_missing", false)}
      _ -> {:error, :invalid_argument, "`create_if_missing` must be a boolean"}
    end
  end

  @impl AI.Tools
  def ui_note_on_request(%{"file" => file}) do
    {"Preparing changes", AI.Tools.display_path(file)}
  end

  @impl AI.Tools
  def ui_note_on_result(%{"file" => file}, _result) do
    {"Changes applied", AI.Tools.display_path(file)}
  end

  @impl AI.Tools
  def tool_call_failure_message(_args, reason), do: reason

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

        **Three editing modes:**
        1. **Hash-Anchored Replacement** (preferred): Provide hashes + old_string + new_string.
           Each hash is a `line:hash` identifier copied from file_contents_tool output
           (e.g. from `42:a3f1|text`, the identifier is `"42:a3f1"`).
           List one identifier for each contiguous line in the region to replace. This is the
           most reliable mode because the line number pinpoints the location and the hash
           verifies the content hasn't changed.
        2. **Exact String Matching**: Provide old_string/new_string for precise replacements.
           Use when you know the exact text to change.
        3. **Natural Language**: Provide descriptive change instructions for the AI to interpret.
           Use when you need contextual understanding.
           Do not assume the AI has the same context as you!
           Be explicit, as though instructing someone seeing the file for the first time.
           **TIP:** Split non-contiguous changes into separate tool call requests for the same file.

        Use for:
        - One-off line or block replacements
        - Clear, unambiguous, file-local changes
        - Fast, low-risk operations
        - Creating temporary scripts to assist with:
          - complex tasks
          - validating hypotheses
          - analyzing code behavior
          - processing data
          - testing fixes and proving theories about bugs

        Supports optional creation of the file when it does not exist by
        setting `create_if_missing: true`.

        **Examples:**

        Hash-anchored replacement (preferred):
        ```json
        {
          "file": "src/app.js",
          "changes": [{
            "hashes": ["3:a3f1", "4:f10e", "5:0e5d"],
            "old_string": "const API_URL = 'localhost';\nconst API_KEY = 'old';\nconst TIMEOUT = 3000;",
            "new_string": "const API_URL = 'api.example.com';\nconst API_KEY = 'xxx';\nconst TIMEOUT = 5000;"
          }]
        }
        ```
        Each hash is a `line:hash` identifier from file_contents_tool (e.g. line `3:a3f1|const API_URL = 'localhost'` has identifier `"3:a3f1"`).
        List one identifier per contiguous line in the region you want to replace.
        old_string is the text of those lines (without hashline prefixes) - a comprehension check.

        File editing with exact matching (fallback):
        ```json
        {
          "file": "src/app.js",
          "changes": [{
            "old_string": "const API_URL = 'localhost'",
            "new_string": "const API_URL = 'api.example.com'"
          }]
        }
        ```

        File creation (simplified UX):
        ```json
        {
          "file": "config/new-config.json",
          "create_if_missing": true,
          "changes": [{
            "new_string": "{\"version\": \"1.0\", \"debug\": true}"
          }]
        }
        ```

        Natural language instruction:
        ```json
        {
          "file": "components/Header.tsx",
          "changes": [{
            "instructions": "Add a new prop called 'showLogo' to the Header component and use it to conditionally render the logo"
          }]
        }
        ```

        **Best practices:**
        - Use the file_contents_tool to read the file before editing.
        - **Prefer hash-anchored edits**: read the file, collect the `line:hash`
          identifiers for the lines you want to change, and pass them as the
          `hashes` array. This is the most reliable editing mode.
        - When using hashes, list one `line:hash` identifier per line in the
          contiguous region to replace. Line numbers must be consecutive.
        - When using old_string, it must contain the raw file text, NOT the
          hashline-prefixed output from file_contents_tool.
        - For new files: omit old_string and use create_if_missing: true at the TOP LEVEL
        - Split complex edits into multiple changes/tool calls
        - Keep diffs minimal and well-anchored

        Limitations:
        - This tool edits the contents of a single file.
        - It does not delete, move, or rename files or directories.
        - Do NOT use file_edit_tool to "delete" a file by truncating it to empty content.

        For operations where the primary intent is to remove or move a file
        (for example: "delete this file from the project" or "move this file to
        a new path"), prefer cmd_tool with appropriate commands (such as
        `rm`, `mv`, or `git mv`).

        Tool choice:
        - Use file_edit_tool when:
          - You are changing or adding code inside a single existing file, and
          - The file should continue to exist at the same path.
        - Use cmd_tool when:
          - You need to delete, move, or rename files or directories, or
          - You are applying changes that naturally affect many files at once.
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
              description: """
              A list of changes to apply to the file.
              Steps are ordered logically, with each building on the previous.
              They will be applied in sequence.

              Each change can be either:
              1. Natural language instructions (for AI interpretation)
              2. Exact string replacement (for precise, reliable edits)
              """,
              items: %{
                type: "object",
                oneOf: [
                  %{
                    description: "Hash-anchored replacement (preferred)",
                    type: "object",
                    required: ["hashes", "old_string", "new_string"],
                    additionalProperties: false,
                    properties: %{
                      hashes: %{
                        type: "array",
                        items: %{type: "string"},
                        description: """
                        Ordered list of `line:hash` identifiers, one per line in the
                        contiguous region to replace. Each identifier is the line number
                        and content hash from file_contents_tool output (e.g. from line
                        "42:a3f1|text", the identifier is "42:a3f1"). Line numbers must
                        be consecutive integers. Do NOT include line content - only the
                        `line:hash` prefix (e.g. from "129:a3f1|UI.fatal(...", use
                        "129:a3f1", NOT "129:a3f1|UI.fatal(...").
                        """
                      },
                      old_string: %{
                        type: "string",
                        description: """
                        The text content of the lines identified by hashes, copied from
                        the file WITHOUT hashline prefixes. This is a comprehension check:
                        it proves you read the target region correctly. Leading whitespace
                        differences are tolerated, but the content must match.
                        """
                      },
                      new_string: %{
                        type: "string",
                        description: """
                        The replacement text for the identified line range. Whitespace
                        fitting is applied automatically to match surrounding indentation.
                        """
                      }
                    }
                  },
                  %{
                    description: "Natural language change instruction",
                    type: "object",
                    required: ["instructions"],
                    additionalProperties: false,
                    properties: %{
                      instructions: %{
                        type: "string",
                        description: """
                        Clear, specific natural language instructions for the changes to make. The
                        instructions must be concise and unambiguous.

                        Clearly define the section(s) of the file to modify. Provide
                        unambiguous "anchors" that identify the exact location of the
                        change.

                        Examples:
                        - "Immediately after the declaration of the main function, add the following code block: ..."
                        - "Replace the entire contents of the calculate function with: ..."
                        - "At the top of the file, insert the following imports: ..."
                        """
                      },
                      context: %{
                        type: "string",
                        description: """
                        Optional background context for the AI that will interpret the
                        instructions. The Patcher agent does not share your conversation
                        history - it sees only the file and the instruction. Use this
                        field to provide rationale, constraints, conventions, or scope
                        that help the Patcher understand *why* the change is needed and
                        how it fits into the broader task.
                        """
                      }
                    }
                  },
                  %{
                    description: "Exact string replacement",
                    type: "object",
                    required: ["old_string", "new_string"],
                    additionalProperties: false,
                    properties: %{
                      old_string: %{
                        type: "string",
                        description: """
                        Exact string to replace. Must match exactly (including whitespace)
                        or the operation will fail. For file creation, use empty string "".
                        """
                      },
                      new_string: %{
                        type: "string",
                        description: """
                        Exact replacement string. When used with old_string, replaces all matches.
                        For file creation, this becomes the entire file content.
                        """
                      },
                      replace_all: %{
                        type: "boolean",
                        description: """
                        Whether to replace all occurrences (true) or fail if old_string appears
                        multiple times (false). Defaults to false for safety.
                        """,
                        default: false
                      }
                    }
                  },
                  %{
                    description: "File creation (simplified UX)",
                    type: "object",
                    required: ["new_string"],
                    additionalProperties: false,
                    properties: %{
                      new_string: %{
                        type: "string",
                        description: """
                        Complete file content for new file creation.
                        Must be used with create_if_missing: true at the top level.
                        """
                      }
                    }
                  }
                ]
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
    with :ok <- AI.Tools.require_worktree_if_git(),
         {:ok, args} <- read_args(raw_args),
         {:ok, file} <- AI.Tools.get_arg(args, "file"),
         {:ok, changes} <- read_changes(args) do
      create? = Map.get(args, "create_if_missing", false)

      with {:ok, result} <- do_edits(file, changes, create?) do
        {:ok, result}
      end
    end
  end

  # Parse and validate the list of change instructions
  @spec read_changes(map) :: {:ok, [change]} | {:error, String.t()}
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
  @type natural_language :: %{
          type: :natural_language,
          instruction: String.t(),
          context: String.t() | nil
        }

  @type exact :: %{
          type: :exact,
          old_string: String.t(),
          new_string: String.t(),
          replace_all: boolean()
        }

  @type hash_anchored :: %{
          type: :hash_anchored,
          hashes: [String.t()],
          old_string: String.t(),
          new_string: String.t()
        }

  @type change ::
          natural_language
          | exact
          | hash_anchored

  @spec parse_change(map) :: {:ok, change} | {:error, String.t()}
  defp parse_change(change_map) when is_map(change_map) do
    instruction = Map.get(change_map, "instructions", "")
    hashes = Map.get(change_map, "hashes")
    old_string = Map.get(change_map, "old_string")
    new_string = Map.get(change_map, "new_string")
    replace_all = Map.get(change_map, "replace_all", false)

    cond do
      # Hash-anchored replacement (preferred for editing existing content)
      hashes != nil and is_list(hashes) and old_string != nil and new_string != nil ->
        with true <- is_binary(old_string) and is_binary(new_string),
             {:ok, _parsed} <- Patchwork.parse_hashline_ids(hashes) do
          {:ok,
           %{
             type: :hash_anchored,
             hashes: hashes,
             old_string: old_string,
             new_string: new_string
           }}
        else
          false ->
            {:error, "old_string and new_string must be strings"}

          {:error, reason} ->
            {:error, reason}
        end

      # Exact string matching mode (full parameters)
      old_string != nil and new_string != nil ->
        if is_binary(old_string) and is_binary(new_string) and is_boolean(replace_all) do
          {:ok,
           %{
             type: :exact,
             old_string: old_string,
             new_string: new_string,
             replace_all: replace_all
           }}
        else
          {:error, "old_string and new_string must be strings, replace_all must be boolean"}
        end

      # File creation mode (new_string only, for create_if_missing)
      old_string == nil and new_string != nil ->
        # Check for common agent confusion: trying to insert content into existing file
        # Look for indicators that this might be content insertion, not file creation
        create_if_missing = Map.get(change_map, "create_if_missing")

        cond do
          # Agent explicitly said create_if_missing: false - they're confused about insertion
          create_if_missing == false ->
            {:error,
             """
             Invalid parameters for content insertion. You provided new_string without old_string,
             but also set create_if_missing: false, indicating you want to modify an existing file.

             For inserting content into an existing file, you have two options:

             1. Exact string matching - specify where to insert:
                {"old_string": "existing code to insert after", "new_string": "existing code + new content"}

             2. Natural language - describe the location:
                {"instructions": "Add the new function after the existing helper functions"}

             Note: create_if_missing belongs at the top level, not inside individual changes.
             """}

          # Agent has create_if_missing inside the change (wrong placement)
          create_if_missing != nil ->
            {:error,
             """
             Parameter placement error: create_if_missing should be at the top level, not inside changes.

             Correct structure:
             {
               "file": "path/to/file.ex",
               "create_if_missing": true,
               "changes": [{"new_string": "file content"}]
             }

             For adding content to existing files, use exact matching or natural language instead.
             """}

          # Standard file creation mode
          is_binary(new_string) and is_boolean(replace_all) ->
            {:ok,
             %{
               type: :exact,
               old_string: "",
               new_string: new_string,
               replace_all: replace_all
             }}

          true ->
            {:error, "new_string must be a string, replace_all must be boolean"}
        end

      # Partial exact string matching (error case)
      old_string != nil and new_string == nil ->
        {:error,
         """
         Both old_string and new_string must be provided together for exact matching.
         For file creation, you can omit old_string and just provide new_string.
         Example for editing: {"old_string": "old text", "new_string": "new text"}
         Example for file creation: {"new_string": "file content"} with create_if_missing: true
         """}

      # Natural language mode
      instruction != "" ->
        context = Map.get(change_map, "context")

        {:ok,
         %{
           type: :natural_language,
           instruction: String.trim(instruction),
           context: if(is_binary(context) and byte_size(context) > 0, do: context, else: nil)
         }}

      # No valid parameters
      true ->
        {:error,
         """
         Invalid change parameters. You must provide either:
         1. Natural language: {"instructions": "description of what to do"}
         2. Exact matching: {"old_string": "text to replace", "new_string": "replacement text"}
         3. File creation: {"new_string": "content"} with create_if_missing: true at the top level
         """}
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
  @spec do_edits(binary, [change], boolean) :: {:ok, edit_result} | {:error, String.t()}
  defp do_edits(file, changes, create_if_missing) do
    try do
      with {:ok, project} <- Store.get_project(),
           absolute_path = Store.Project.expand_path(file, project),
           _ =
             UI.debug(
               "file_edit",
               "do_edits: source_root=#{project.source_root} file=#{file} abs=#{absolute_path}"
             ),
           {orig_exists, orig_text} = read_file(absolute_path),
           base_hash = :crypto.hash(:sha256, orig_text),
           :ok <- ensure_file(absolute_path, create_if_missing),
           {:ok, contents} <- apply_all_changes(absolute_path, orig_text, changes) do
        if contents == orig_text do
          {:error, "no changes were made to the file"}
        else
          with {:ok, diff, bak} <- stage_changes(absolute_path, contents, orig_exists, base_hash) do
            {:ok, %{file: file, diff: diff, backup_file: bak}}
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
      else
        error ->
          UI.debug("file_edit", "stage_changes failed: #{inspect(error)}")
          error
      end
    end)
  end

  # Apply all changes sequentially, handling both exact and natural language changes
  @spec apply_all_changes(binary, binary, [change]) :: {:ok, binary} | {:error, String.t()}
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
  @spec validate_change(change, binary) :: :ok | {:error, String.t()}
  defp validate_change(%{type: :exact, old_string: old}, contents) when byte_size(old) == 0 do
    # Allow empty old_string only when creating a new file (empty contents)
    # This supports the file creation UX where agents can omit old_string
    if byte_size(contents) == 0 do
      :ok
    else
      {:error,
       "old_string cannot be empty when editing existing content (use create_if_missing: true for new files)"}
    end
  end

  defp validate_change(%{type: :natural_language, instruction: instruction}, _contents) do
    cond do
      String.length(String.trim(instruction)) < 10 ->
        {:error,
         """
         Instruction too vague. Please provide more specific details about what to change and where.
         Examples: "Add error handling to the login function", "Replace the hardcoded API URL on line 42"
         """}

      not (String.contains?(String.downcase(instruction), [
             "after",
             "before",
             "at the",
             "in the",
             "replace",
             "add",
             "remove",
             "delete",
             "update",
             "change",
             "rename",
             "move",
             "function",
             "module",
             "class",
             "method",
             "comment",
             "import",
             "line",
             "top",
             "bottom",
             "beginning",
             "end of"
           ]) or
               Regex.match?(~r/\d+/, instruction)) ->
        {:error,
         """
         Instruction lacks clear location anchors. Consider specifying:
         - Hashline identifiers: "at line 42:a3", "lines 10:f1 through 15:0e"
         - Function names: "in the validateUser function"
         - Relative positions: "before the return statement", "after the imports"
         - Specific text: "replace 'localhost' with 'api.example.com'"
         """}

      true ->
        :ok
    end
  end

  defp validate_change(_change, _contents), do: :ok

  # Apply a single change based on its type
  @spec apply_single_change(binary, binary, change) :: {:ok, binary} | {:error, String.t()}
  defp apply_single_change(_file, contents, %{type: :hash_anchored} = change) do
    Patchwork.patch_by_hashes(contents, change.hashes, change.old_string, change.new_string)
  end

  defp apply_single_change(_file, contents, %{type: :exact} = change) do
    Patchwork.patch(contents, change)
  end

  defp apply_single_change(file, contents, %{type: :natural_language} = change) do
    apply_natural_language_change(file, contents, change.instruction, change.context)
  end

  # Handle natural language changes using the existing patcher. The optional
  # context field passes coordinator-level background (rationale, constraints,
  # conventions) through to the Patcher so it can make informed decisions
  # instead of guessing intent from the instruction alone.
  @spec apply_natural_language_change(binary, binary, String.t(), String.t() | nil) ::
          {:ok, binary} | {:error, String.t()}
  defp apply_natural_language_change(file, _contents, instruction, context) do
    AI.Agent.Code.Patcher
    |> AI.Agent.new()
    |> AI.Agent.get_response(%{file: file, changes: [instruction], context: context})
  end

  # Format error messages with context about which change failed
  @spec format_change_error(change, String.t()) :: String.t()
  defp format_change_error(%{type: :hash_anchored, hashes: hashes}, reason) do
    # The full error (including hashes) always goes back to the LLM via
    # tool_call_failure_message. The hashes dump is noisy in the user's
    # terminal, so we only include it when FNORD_DEBUG_EDITS is set.
    hashes_detail =
      if System.get_env("FNORD_DEBUG_EDITS"),
        do: "Hashes: #{inspect(hashes)}\n",
        else: ""

    """
    Hash-anchored replacement failed:
    #{hashes_detail}Error: #{reason}

    Suggestions:
    - Re-read the file with file_contents_tool to get current hashes
    - Verify old_string matches the content of the lines you are targeting
    - Ensure hashes form a contiguous sequence in the file
    """
  end

  defp format_change_error(%{type: :exact, old_string: old}, reason) do
    """
    Exact string replacement failed:
    Searching for: #{inspect(old)}
    Error: #{reason}

    Suggestions:
    - Verify the exact string exists in the file, including all whitespace and capitalization
    - If creating a new file, use create_if_missing: true at the TOP LEVEL (not inside changes array)
    - For multiple occurrences, add "replace_all": true to the change object
    """
  end

  defp format_change_error(%{type: :natural_language, instruction: instruction}, reason) do
    """
    Natural language instruction failed:
    Instruction: "#{instruction}"
    Error: #{reason}

    Suggestions:
    - Use *exact string replacement* for more reliable results:
      {"old_string": "exact text to find", "new_string": "replacement text"}
    - Make instructions more specific with clear anchors (line numbers, function names)
    - For new files, use create_if_missing: true at the TOP LEVEL, not inside changes
    - Break complex changes into smaller, more specific steps
    - **Don't assume the LLM implementing your semantic change has the same context as you**
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

  # Skip backups when working in a fnord-managed worktree — the worktree
  # branch is itself an isolation mechanism, making .bak files redundant.
  defp backup_file(file) do
    case Settings.get_project_root_override() do
      nil ->
        Services.BackupFile.create_backup(file)

      path ->
        with {:ok, project} <- Store.get_project(),
             true <- GitCli.Worktree.fnord_managed?(project.name, path) do
          {:ok, nil}
        else
          _ -> Services.BackupFile.create_backup(file)
        end
    end
  end

  @spec commit_changes(binary, binary) :: :ok | {:error, term}
  defp commit_changes(file, staged) do
    # Perform atomic write: copy staged content to a temp file, then rename over target
    dir = Path.dirname(file)
    tmp = Path.join(dir, ".#{Path.basename(file)}.tmp")

    UI.debug("file_edit", "commit_changes: target=#{file}")
    UI.debug("file_edit", "commit_changes: staged=#{staged} exists=#{File.exists?(staged)}")

    case File.cp(staged, tmp) do
      :ok ->
        case File.rename(tmp, file) do
          :ok ->
            # Verify the write actually landed
            case File.stat(file) do
              {:ok, %{size: size}} ->
                UI.debug("file_edit", "commit_changes: success, size=#{size}")

              {:error, reason} ->
                UI.debug("file_edit", "commit_changes: stat after rename failed: #{reason}")
            end

            :ok

          {:error, reason} ->
            UI.debug("file_edit", "commit_changes: rename failed: #{reason}")
            {:error, reason}
        end

      {:error, reason} ->
        UI.debug("file_edit", "commit_changes: cp failed: #{reason}")
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

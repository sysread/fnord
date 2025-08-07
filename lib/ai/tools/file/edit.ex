defmodule AI.Tools.File.Edit do
  @moduledoc """
  String-based code editing tool that uses exact and fuzzy string matching
  instead of line numbers. Handles whitespace normalization while preserving
  original formatting and indentation.
  """

  @max_needle_length 5000

  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: false

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def read_args(args) do
    with {:ok, path} <- AI.Tools.get_arg(args, "path"),
         {:ok, old_string} <- AI.Tools.get_arg(args, "old_string") do
      # Handle new_string specially to allow empty strings (for deletion)
      new_string = Map.get(args, "new_string", "")

      {:ok,
       %{
         "path" => path,
         "old_string" => old_string,
         "new_string" => new_string
       }}
    end
  end

  @impl AI.Tools
  def ui_note_on_request(%{"path" => path, "old_string" => old, "new_string" => new}) do
    diff_output = generate_diff(old, new, path)
    {"Editing #{path}", diff_output}
  end

  @impl AI.Tools
  def ui_note_on_result(%{"path" => path}, result) do
    {"Changes applied to #{path}", result}
  end

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "file_edit_tool",
        description: """
        Edit existing files by finding and replacing exact strings using position-based splicing.
        Uses fuzzy matching to handle whitespace differences while preserving original
        formatting and indentation.

        NOTE: This tool can only edit existing files. To create new files, use file_manage_tool first.

        CRITICAL SUCCESS FACTORS:
        - Include enough context in old_string to make it unique in the file
        - Copy text exactly from the file, including indentation and spacing
        - Use file_contents_tool first to see the exact text formatting
        - The old_string should contain exactly what you want to replace
        - Pay special attention to whitespace and indentation;
          carefully consider how the replacement will affect whitespace

        💡 TIP: To avoid duplication, include the entire section you want to replace in old_string, not just a small part like a header.
        For example:
        - BAD:  old_string: "## Features"
        - GOOD: old_string: "## Features\\n\\n- Feature 1\\n- Feature 2"

        EXAMPLES OF GOOD old_string VALUES:
        ```
        function calculateTotal(items) {
          let sum = 0;
          for (let item of items) {
            sum += item.price;
          }
          return sum;
        }
        ```

        EXAMPLES OF BAD old_string VALUES:
        - `let sum = 0;` (too short, likely multiple matches)
        - `calculateTotal` (just the function name, not enough context)
        - `line1\\nline2\\nline3` (escaped newlines - use real line breaks instead!)
        """,
        parameters: %{
          type: "object",
          required: ["path", "old_string"],
          properties: %{
            path: %{
              type: "string",
              description: """
              Path (relative to project root) of the file to edit.
              """
            },
            old_string: %{
              type: "string",
              description: """
              The exact text to find and replace.
              MUST be unique in the file - if multiple matches are found, you must add more context.
              MUST include enough surrounding context (2-3 lines before/after) to make it unique in the file.
              Copy this text exactly from the file, preserving all whitespace and indentation.
              Cannot be empty - this tool only edits existing files.
              """
            },
            new_string: %{
              type: "string",
              description: """
              The replacement text. Optional - if not provided or empty, the old_string will be deleted.
              Indentation will be preserved from the original.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(args) do
    with {:ok, path} <- AI.Tools.get_arg(args, "path"),
         {:ok, old_string} <- AI.Tools.get_arg(args, "old_string"),
         {:ok, project} <- Store.get_project() do
      # Handle new_string specially to allow empty strings (for deletion)
      new_string = Map.get(args, "new_string", "")

      abs_path = Store.Project.expand_path(path, project)

      with :ok <- validate_path_for_edit(abs_path, project.source_root),
           :ok <- validate_needle_length(old_string),
           {:ok, contents} <- File.read(abs_path),
           {:ok, updated, match} <-
             find_and_replace_with_validation_impl(contents, old_string, new_string) do
        apply_changes(abs_path, path, updated, match)
      else
        {:error, :enoent} ->
          {:error,
           """
           File #{args["path"]} does not exist.
           This tool can only edit existing files. Use file_manage_tool to create new files first.
           NO CHANGES WERE MADE.
           """}

        {:error, :not_found} ->
          {:error,
           """
           Could not find the specified text in #{args["path"]}.
           Make sure old_string matches exactly (including whitespace).
           NO CHANGES WERE MADE.
           """}

        {:error, :multiple_matches} ->
          {:error,
           """
           Found multiple matches for the specified text in #{args["path"]}.
           Please include more context to make old_string unique.
           NO CHANGES WERE MADE.
           """}

        {:error, :needle_length} ->
          {:error,
           """
           The value you supplied for `old_string` is is too long.
           The maximum length is #{@max_needle_length} characters.
           NO CHANGES WERE MADE.
           """}

        {:error, reason} ->
          {:error,
           """
           File change failed for #{args["path"]}:
           #{inspect(reason)}

           NO CHANGES WERE MADE.
           """}
      end
    end
  end

  # ----------------------------------------------------------------------------
  # Private Functions (some exposed for testing)
  # ----------------------------------------------------------------------------

  defp validate_needle_length(needle) do
    if String.length(needle) > @max_needle_length do
      {:error, :needle_length}
    else
      :ok
    end
  end

  # Generate a colored diff using the system diff utility
  defp generate_diff(old_string, new_string, path) do
    with {:ok, temp_dir} <- Briefly.create(directory: true),
         old_file <- Path.join(temp_dir, "old_#{Path.basename(path)}"),
         new_file <- Path.join(temp_dir, "new_#{Path.basename(path)}"),
         :ok <- File.write(old_file, old_string),
         :ok <- File.write(new_file, new_string) do
      # Use diff -u for unified diff format
      case System.cmd("diff", ["-u", old_file, new_file], stderr_to_stdout: true) do
        {_output, 0} ->
          # No differences (shouldn't happen in practice)
          "No changes detected"

        {output, 1} ->
          # Differences found (normal case - this is what we want)
          clean_diff_output(output)

        {output, 2} ->
          # Error occurred (file not found, permission issues, etc.)
          "Error generating diff: #{String.trim(output)}"

        {output, exit_code} ->
          # Unexpected exit code
          "Unexpected diff exit code #{exit_code}: #{String.trim(output)}"
      end
    else
      error ->
        # Fallback to simple preview if diff fails
        old_preview =
          String.slice(old_string, 0, 100) <>
            if String.length(old_string) > 100, do: "...", else: ""

        new_preview =
          String.slice(new_string, 0, 100) <>
            if String.length(new_string) > 100, do: "...", else: ""

        "#{old_preview} → #{new_preview} (diff unavailable: #{inspect(error)})"
    end
  end

  # Clean up diff output and add colors
  defp clean_diff_output(diff_output) do
    diff_output
    |> String.split("\n")
    # Remove the file path lines (--- and +++ headers)
    |> Enum.drop(2)
    # Remove newline warnings
    |> Enum.reject(&String.contains?(&1, "No newline at end of file"))
    |> Enum.map(&colorize_diff_line/1)
    |> Enum.join("\n")
    |> String.trim()
  end

  # Add ANSI color codes to diff lines
  defp colorize_diff_line(line) do
    cond do
      # Green for additions
      String.starts_with?(line, "+") and not String.starts_with?(line, "+++") ->
        IO.ANSI.format([:green_background, :black, line])

      # Red for deletions
      String.starts_with?(line, "-") and not String.starts_with?(line, "---") ->
        IO.ANSI.format([:red_background, :black, line])

      # Cyan for hunk headers
      String.starts_with?(line, "@@") ->
        IO.ANSI.format([:cyan, line])

      # No color for context lines
      true ->
        line
    end
  end

  # Expose some private functions for testing
  if Mix.env() == :test do
    def normalize_for_matching(text), do: normalize_for_matching_impl(text)

    def find_and_replace(content, old_string, new_string),
      do: find_and_replace_impl(content, old_string, new_string)

    def find_fuzzy_matches(content, normalized_target),
      do: find_fuzzy_matches_impl(content, normalized_target)

    def find_original_boundaries(content, start_pos, normalized_target),
      do: find_original_boundaries_impl(content, start_pos, normalized_target)
  end

  defp validate_path_for_edit(path, root) do
    cond do
      !Util.path_within_root?(path, root) -> {:error, "not within project root"}
      true -> :ok
    end
  end

  # Find and replace with uniqueness validation
  defp find_and_replace_with_validation_impl(content, old_string, new_string) do
    # First check if old_string appears multiple times (uniqueness validation)
    case :binary.matches(content, old_string) do
      [] ->
        # Not found, try fuzzy matching
        fuzzy_find_and_replace_impl(content, old_string, new_string)

      [_single_match] ->
        # Exactly one match, proceed with normal replacement
        find_and_replace_impl(content, old_string, new_string)

      [_first | _rest] ->
        # Multiple matches, this violates uniqueness
        {:error, :multiple_matches}
    end
  end

  # The core matching algorithm using position-based splicing
  defp find_and_replace_impl(content, old_string, new_string) do
    # Step 1: Try exact match first
    case find_match_position(content, old_string) do
      {:ok, start_pos, length} ->
        # Direct splice replacement - no adjustment needed
        before = String.slice(content, 0, start_pos)
        after_match = String.slice(content, start_pos + length, String.length(content))

        {:ok, before <> new_string <> after_match,
         %{type: :exact, position: start_pos, length: length}}

      {:error, :multiple_matches} ->
        {:error, :multiple_matches}

      {:error, :not_found} ->
        # Step 2: Try fuzzy matching with position-based approach
        fuzzy_find_and_replace_impl(content, old_string, new_string)
    end
  end

  # Find exact match position, return start position and length
  defp find_match_position(content, target) do
    case :binary.matches(content, target) do
      [] ->
        {:error, :not_found}

      [{start_pos, length}] ->
        {:ok, start_pos, length}

      [_first | _rest] ->
        {:error, :multiple_matches}
    end
  end

  # Fuzzy matching with whitespace normalization
  defp fuzzy_find_and_replace_impl(content, old_string, new_string) do
    # Check for very long strings that might cause performance issues
    if String.length(old_string) > 500 do
      # IO.puts("WARNING: Very long old_string (#{String.length(old_string)} chars), this might be slow")
    end

    # Check for escaped newlines - this is a major performance killer
    escaped_newlines = String.contains?(old_string, "\\n")
    actual_newlines = String.contains?(old_string, "\n")

    if escaped_newlines and not actual_newlines do
      {:error,
       "old_string contains escaped newlines (\\n) instead of actual newlines. This suggests the text was improperly formatted. Please copy the text directly from the file with real line breaks."}
    else
      normalized_target = normalize_for_matching_impl(old_string)

      # Additional safety check for normalized target
      if String.length(normalized_target) > 1000 do
        {:error,
         "Normalized search string too long (#{String.length(normalized_target)} chars). Please use a shorter, more specific string."}
      else
        # Find all potential matches by sliding window
        try do
          content
          |> find_fuzzy_matches_impl(normalized_target)
          |> case do
            [] -> {:error, :not_found}
            [match] -> apply_fuzzy_replacement(content, match, new_string)
            [_ | _] -> {:error, :multiple_matches}
          end
        catch
          {:timeout, msg} -> {:error, msg}
        end
      end
    end
  end

  # Normalize text for matching (but preserve original structure)
  defp normalize_for_matching_impl(text) do
    text
    # Collapse whitespace
    |> String.replace(~r/\s+/, " ")
    # Trim edges
    |> String.replace(~r/^\s+|\s+$/, "")
    # Case insensitive
    |> String.downcase()
  end

  # Find potential matches using sliding window
  defp find_fuzzy_matches_impl(content, normalized_target) do
    target_length = String.length(normalized_target)
    content_length = String.length(content)

    if target_length == 0 or content_length == 0 do
      []
    else
      # Much more aggressive limits for performance
      max_positions =
        cond do
          # Very long targets get very limited search
          target_length > 200 -> 50
          # Long targets get limited search
          target_length > 100 -> 200
          # Normal case, reduced from 5000
          true -> Enum.min([content_length - target_length, 1000])
        end

      # IO.puts("Fuzzy search: target_length=#{target_length}, max_positions=#{max_positions}")

      start_time = System.monotonic_time(:millisecond)

      result =
        0..max_positions
        |> Stream.map(fn start_pos ->
          # Timeout check every 100 iterations
          if rem(start_pos, 100) == 0 do
            elapsed = System.monotonic_time(:millisecond) - start_time
            # 3 second timeout
            if elapsed > 3000 do
              throw({:timeout, "Fuzzy search took too long (#{elapsed}ms), stopping"})
            end
          end

          find_original_boundaries_impl(content, start_pos, normalized_target)
        end)
        |> Stream.reject(&is_nil/1)
        # Stop after finding 3 matches max (reduced from 5)
        |> Enum.take(3)

      result
    end
  end

  # The key insight: find the original text boundaries that normalize to our target
  defp find_original_boundaries_impl(content, start_pos, normalized_target) do
    # Expand window until we capture enough text that normalizes to our target
    min_length = String.length(normalized_target)
    remaining_content = String.length(content) - start_pos
    # Much more aggressive limits to prevent exponential blowup
    # Reduced from 1000!
    max_length = Enum.min([min_length + 50, remaining_content, 200])

    if max_length < min_length or min_length == 0 do
      nil
    else
      # Instead of checking every length, use binary search approach
      # Check lengths at: min, min+10, min+20, ..., max
      # Max 10 steps
      step_size = max(1, div(max_length - min_length, 10))

      min_length..max_length
      |> Stream.take_every(step_size)
      |> Enum.find_value(fn length ->
        candidate = String.slice(content, start_pos, length)
        normalized_candidate = normalize_for_matching_impl(candidate)

        if normalized_candidate == normalized_target do
          %{start: start_pos, length: length, original: candidate}
        end
      end)
    end
  end

  # Apply replacement using position-based splicing
  defp apply_fuzzy_replacement(content, match, new_string) do
    %{start: start_pos, length: length} = match

    before = String.slice(content, 0, start_pos)
    after_match = String.slice(content, start_pos + length, String.length(content))

    # Preserve indentation from original
    indentation = extract_leading_whitespace(match.original)
    formatted_replacement = apply_indentation(new_string, indentation)

    updated = before <> formatted_replacement <> after_match
    {:ok, updated, %{type: :fuzzy, position: start_pos, length: length}}
  end

  # Extract leading whitespace to preserve indentation
  defp extract_leading_whitespace(text) do
    case Regex.run(~r/^(\s*)/, text) do
      [_, whitespace] -> whitespace
      _ -> ""
    end
  end

  # Apply consistent indentation to replacement text
  defp apply_indentation(text, indentation) do
    text
    |> String.split("\n")
    |> Enum.map(fn
      # Empty lines stay empty
      "" -> ""
      line -> indentation <> String.trim_leading(line)
    end)
    |> Enum.join("\n")
  end

  # Apply the changes with backup
  defp apply_changes(abs_path, rel_path, updated_contents, match_info) do
    with {:ok, backup} <- backup_file(abs_path),
         {:ok, temp} <- Briefly.create(),
         :ok <- File.write(temp, updated_contents),
         :ok <- File.rename(temp, abs_path) do
      # Generate context preview showing the changes in context
      context_preview = generate_context_preview(updated_contents, match_info, rel_path)

      backup_message =
        if backup do
          "#{rel_path} is backed up as #{backup}."
        else
          "#{rel_path} was created (no backup needed)."
        end

      {:ok,
       """
       #{rel_path} was modified successfully using #{match_info[:type]} matching.
       #{backup_message}

       #{context_preview}
       """}
    end
  end

  # Generate a preview showing the modified section with surrounding context
  defp generate_context_preview(content, match_info, file_path) do
    lines = String.split(content, "\n")
    total_lines = length(lines)

    # Calculate which lines the change affects
    %{position: start_pos} = match_info
    text_before_change = String.slice(content, 0, start_pos)

    # Find the line number where the change starts (1-based)
    change_start_line = text_before_change |> String.split("\n") |> length()

    # Show context: 10 lines before and after the change area
    context_start = max(1, change_start_line - 10)
    context_end = min(total_lines, change_start_line + 20)

    context_lines =
      lines
      |> Enum.slice(context_start - 1, context_end - context_start + 1)
      # Line numbers start from context_start
      |> Enum.with_index(context_start)
      |> Enum.map(fn {line, line_num} ->
        # Show which line was the target of the change
        if line_num == change_start_line do
          "#{String.pad_leading(to_string(line_num), 4)}→ #{line}  ← CHANGE STARTED HERE"
        else
          "#{String.pad_leading(to_string(line_num), 4)}  #{line}"
        end
      end)
      |> Enum.join("\n")

    """
    ⚠️  CRITICAL: REVIEW YOUR CHANGES CAREFULLY ⚠️

    The file #{file_path} has been modified.
    Here's how your changes appear in context:

    #{context_lines}

    ⚠️  IF THE CHANGES LOOK WRONG (e.g., duplicated content):
    1. Use file_contents_tool to examine the current state
    2. Use coder_tool again with a more specific old_string that includes MORE context
    3. Make sure your old_string contains exactly what you want to replace

    💡 TIP: To avoid duplication, include the entire section you want to replace in old_string, not just a small part like a header.
    For example:
    - BAD:  old_string: "## Features"
    - GOOD: old_string: "## Features\\n\\n- Feature 1\\n- Feature 2"
    """
  end

  # Create backup file (borrowed from original File.Edit tool)
  defp backup_file(file) do
    # If the file doesn't exist, no backup is needed
    if File.exists?(file) do
      with {:ok, backup} <- Once.get(file) do
        {:ok, backup}
      else
        {:error, :not_seen} ->
          case backup_file(file, 0) do
            {:ok, backup} ->
              Once.set(file, backup)
              {:ok, backup}

            {:error, reason} ->
              {:error, reason}
          end
      end
    else
      {:ok, nil}
    end
  end

  defp backup_file(orig, bak_number) do
    backup = "#{orig}.bak.#{bak_number}"

    if File.exists?(backup) do
      backup_file(orig, bak_number + 1)
    else
      case File.cp(orig, backup) do
        :ok -> {:ok, backup}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end

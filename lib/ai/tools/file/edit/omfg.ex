defmodule AI.Tools.File.Edit.OMFG do
  @moduledoc """
  !@#$%^&*()_+ agents and their %$#@ing parameter shenanigans.

  ## Goddamn Calling Patterns This Handles

  ### The "Patch" Shenanigans
  - `{"patch": "some instruction"}` → converts to proper instructions format
  - `{"changes": [{"patch": "..."}]}` → normalizes patch params within changes

  ### The "Insert After/Before" Madness
  - `{"insert_after": "anchor", "content": "new stuff"}` → natural language instructions
  - `{"insert_before": "anchor", "content": "new stuff"}` → natural language instructions
  - Uses `pattern` field as anchor if provided, otherwise "the specified location"

  ### The "Context + Pattern" Confusion
  - `{"context": "...", "pattern": "old", "content": "new"}` → exact string matching
  - `{"pattern": "find this", "replacement": "replace with"}` → old_string/new_string
  - `{"pattern": "modify this"}` → natural language instruction when no replacement

  ### The "Diff-Style Patch" Nightmare
  - Parses `*** Begin Patch` / `@@` / `---` / `+++` format patches
  - Extracts meaningful `+` and `-` lines into "Add:" / "Remove:" instructions
  - Falls back to using entire diff as instruction if parsing fails

  ### Multiple Shenanigans Simultaneously
  - Handles agents that use multiple insane patterns in one request
  - Preserves unknown parameters for debugging (doesn't break on mystery params)
  - Processes top-level patch + changes array without losing data
  """

  @doc """
  Normalize agent parameter chaos into something resembling sanity.

  Takes whatever creative parameter combinations agents dream up and
  attempts to convert them into the expected format for the file edit tool.

  Returns `{:ok, normalized_args}` or `{:error, reason}` if the shenanigans
  are too creative even for us to handle.
  """
  @spec normalize_agent_chaos(map()) ::
          {:ok, map()}
          | {:error, String.t()}
          | AI.Tools.args_error()
  def normalize_agent_chaos(args) when is_map(args) do
    with {:ok, args} <- patch_the_patch(args),
         {:ok, args} <- handle_insert_after_before(args),
         {:ok, args} <- handle_context_pattern(args),
         {:ok, args} <- handle_diff_style_patches(args) do
      {:ok, args}
    end
  end

  def normalize_agent_chaos(args) do
    {:error, :invalid_argument, "Expected an object, but got: #{inspect(args)}"}
  end

  # Handle agents trying to use "patch" parameter instead of "instructions"
  defp patch_the_patch(%{"patch" => patch, "changes" => existing_changes} = args) do
    # If there are existing changes, prepend the patch as the first change
    new_changes = [%{"instructions" => patch} | existing_changes]

    args
    |> Map.delete("patch")
    |> Map.put("changes", new_changes)
    |> then(&{:ok, &1})
  end

  defp patch_the_patch(%{"patch" => patch} = args) do
    args
    |> Map.delete("patch")
    |> Map.put("changes", [%{"instructions" => patch}])
    |> then(&{:ok, &1})
  end

  defp patch_the_patch(%{"changes" => changes} = args) do
    changes =
      changes
      |> Enum.map(fn
        %{"patch" => patch} -> %{"instructions" => patch}
        other -> other
      end)

    {:ok, Map.put(args, "changes", changes)}
  end

  defp patch_the_patch(args), do: {:ok, args}

  # Handle agents using insert_after/insert_before parameters
  defp handle_insert_after_before(%{"changes" => changes} = args) do
    normalized_changes =
      changes
      |> Enum.map(fn
        change when is_map(change) ->
          cond do
            Map.has_key?(change, "insert_after") -> convert_insert_after(change)
            Map.has_key?(change, "insert_before") -> convert_insert_before(change)
            true -> change
          end

        other ->
          other
      end)

    cond do
      Enum.all?(normalized_changes, &is_map(&1)) ->
        {:ok, Map.put(args, "changes", normalized_changes)}

      true ->
        {:error, :invalid_argument, "All entries in changes must be objects"}
    end
  end

  defp handle_insert_after_before(args), do: {:ok, args}

  # Convert insert_after to natural language instructions
  defp convert_insert_after(%{"insert_after" => content} = change) do
    anchor = Map.get(change, "pattern", "the specified location")
    new_content = Map.get(change, "content", content)
    instruction = "After #{anchor}, insert the following content:\n#{new_content}"
    %{"instructions" => instruction}
  end

  # Convert insert_before to natural language instructions
  defp convert_insert_before(%{"insert_before" => content} = change) do
    anchor = Map.get(change, "pattern", "the specified location")
    new_content = Map.get(change, "content", content)
    instruction = "Before #{anchor}, insert the following content:\n#{new_content}"
    %{"instructions" => instruction}
  end

  # Handle agents using context + pattern combinations
  defp handle_context_pattern(%{"changes" => changes} = args) do
    normalized_changes =
      changes
      |> Enum.map(fn change ->
        case change do
          %{"context" => _context, "pattern" => _pattern} = change_map ->
            convert_context_pattern(change_map)

          %{"pattern" => _pattern} = change_map when not is_map_key(change_map, "old_string") ->
            convert_pattern_only(change_map)

          other ->
            other
        end
      end)

    {:ok, Map.put(args, "changes", normalized_changes)}
  end

  defp handle_context_pattern(args), do: {:ok, args}

  # Convert context + pattern to exact string matching
  defp convert_context_pattern(%{"pattern" => pattern} = change) do
    new_content = Map.get(change, "content", Map.get(change, "replacement", ""))

    if new_content != "" do
      %{
        "old_string" => pattern,
        "new_string" => new_content
      }
    else
      instruction = "Find and modify the code matching: #{pattern}"
      %{"instructions" => instruction}
    end
  end

  # Convert pattern-only to natural language
  defp convert_pattern_only(%{"pattern" => pattern} = change) do
    content = Map.get(change, "content", "")

    if content != "" do
      instruction = "Find the code matching #{pattern} and replace it with:\n#{content}"
      %{"instructions" => instruction}
    else
      instruction = "Modify the code matching: #{pattern}"
      %{"instructions" => instruction}
    end
  end

  # Handle diff-style patch formats
  defp handle_diff_style_patches(%{"changes" => changes} = args) do
    normalized_changes =
      changes
      |> Enum.map(fn change ->
        case change do
          %{"instructions" => instructions} when is_binary(instructions) ->
            if String.contains?(instructions, ["*** Begin Patch", "@@", "--- ", "+++ "]) do
              convert_diff_patch(instructions)
            else
              change
            end

          other ->
            other
        end
      end)

    {:ok, Map.put(args, "changes", normalized_changes)}
  end

  defp handle_diff_style_patches(args), do: {:ok, args}

  # Convert diff-style patch to natural language instructions
  defp convert_diff_patch(diff_content) do
    # Extract meaningful changes from diff format
    instruction =
      diff_content
      |> String.split("\n")
      |> Enum.reduce([], fn line, acc ->
        cond do
          String.starts_with?(line, "+") and not String.starts_with?(line, "+++") ->
            added_line = String.slice(line, 1..-1//1)
            ["Add: #{added_line}" | acc]

          String.starts_with?(line, "-") and not String.starts_with?(line, "---") ->
            removed_line = String.slice(line, 1..-1//1)
            ["Remove: #{removed_line}" | acc]

          true ->
            acc
        end
      end)
      |> Enum.reverse()
      |> Enum.join("\n")

    if String.length(instruction) > 0 do
      %{"instructions" => "Apply the following changes:\n#{instruction}"}
    else
      # Fallback: use the entire diff as instruction
      %{"instructions" => "Apply this patch:\n#{diff_content}"}
    end
  end
end

defmodule AI.Tools.File.Contents do
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: true

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def ui_note_on_request(%{"line_numbers" => true} = args) do
    {"Read +ln", ui_note_file_ref(args)}
  end

  def ui_note_on_request(args) do
    {"Read -ln", ui_note_file_ref(args)}
  end

  defp ui_note_file_ref(%{"file" => file} = args) do
    display = AI.Tools.display_path(file)
    start_line = Map.get(args, "start_line", 1)
    end_line = Map.get(args, "end_line", -1)

    case {start_line, end_line} do
      {1, -1} -> "#{display} (full)"
      {s, e} -> "#{display}:#{s}...#{e}"
    end
  end

  defp ui_note_file_ref(_), do: "invalid args :/"

  @impl AI.Tools
  def ui_note_on_result(_args, _result), do: nil

  @impl AI.Tools
  def tool_call_failure_message(_args, _result), do: :default

  @impl AI.Tools
  def read_args(args) do
    case args do
      %{"file" => _file} -> {:ok, args}
      _ -> {:error, :missing_argument, "file"}
    end
  end

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "file_contents_tool",
        description: """
        Display the contents of a file in the project. Note that this retrieves
        the ENTIRE file. If the file is large, this may fail due to limits on
        the size of messages, or it may pull so much content into your context
        window that you forget the user's prompt or begin hallucinating
        responses. If you only need to learn specific facts or extract a
        section of code, use the file_info_tool to preserve your context
        window.

        This tool reads files by path regardless of index status. It works
        for indexed source files AND for files that are not in the index -
        including gitignored paths like `scratch/` notes. In a worktree
        session, if the file isn't present in the worktree but exists as a
        gitignored file in the original source repo, this tool will fall
        back to reading it from there (and annotate the result with a note
        explaining where it came from). If file_notes_tool, file_search_tool,
        or file_list_tool can't find a path you know exists, reach for this
        tool - it will read it directly.

        Note that this tool ONLY shows the current version of the file on the
        currently checked-out branch. If you need to see the contents of the
        file on a different branch (or for files that only exist on that
        branch), you must use your git tools to retrieve that version of the
        file.
        """,
        parameters: %{
          type: "object",
          required: ["file"],
          properties: %{
            file: %{
              type: "string",
              description: """
              The file whose contents you wish to review. Typically the
              complete path provided by the file_search_tool or file_list_tool,
              but any valid path within the project will work - including
              unindexed and gitignored paths.
              """
            },
            line_numbers: %{
              type: "boolean",
              description: """
              If true (default), prefix each line with a hashline identifier:
              `<line_number>:<content_hash>`, where the content hash is a 2-character
              hex fingerprint of the line's content.
              """,
              default: true
            },
            start_line: %{
              type: "integer",
              description: """
              The 1-based line number to start from. If not provided, defaults
              to the first line. If start_line is outside of the range of lines
              in the file, it will be ignored and the first line of the file
              will be used.
              """,
              default: 1
            },
            end_line: %{
              type: "integer",
              description: """
              The 1-based line number to end at. If not provided, defaults to
              the last line of the file. If end_line is outside of the range of
              lines in the file, it will be ignored and the last line of the
              file will be used.
              """,
              default: nil
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(%{"file" => file} = args) do
    line_numbers = Map.get(args, "line_numbers", true)
    start_line = Map.get(args, "start_line", 1)
    end_line = Map.get(args, "end_line", nil)

    case AI.Tools.get_file_contents_with_origin(file) do
      {:ok, content} ->
        ExternalConfigs.Injector.maybe_inject_for_path(file)

        output =
          content
          |> maybe_number_lines(line_numbers)
          |> maybe_splice_lines(start_line, end_line)
          |> wrap_content(file)

        {:ok, output}

      {:source_fallback, source_path, content} ->
        ExternalConfigs.Injector.maybe_inject_for_path(file)

        output =
          content
          |> maybe_number_lines(line_numbers)
          |> maybe_splice_lines(start_line, end_line)
          |> wrap_content_with_source_fallback(file, source_path)

        {:ok, output}

      {:error, :enoent} ->
        {:error,
         """
         The requested file (#{args["file"]}) does not exist.
         - If the file name is correct (per the list_files_tool), verify the path using the search or the file listing tool.
         - It may have been added since the most recent reindexing of the project.
         - If the file is only present in a topic branch that has not yet been merged, it may not be visible to this tool.
         """}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp wrap_content(text, file) do
    backup_note =
      case Services.BackupFile.describe_backup(file) do
        nil -> ""
        desc -> "#{desc}\n"
      end

    """
    [file_contents_tool] Contents of #{file}:
    Note: Lines are prefixed with `<line_number>:<content_hash>` for identification.
    #{backup_note}```
    #{text}
    ```
    """
  end

  # Wraps the content with a banner explaining that the file came from the
  # source repo via the gitignore source-fallback path, not the worktree.
  # The note tells the LLM how to write back through the worktree so the
  # accumulator preserves the change on merge.
  defp wrap_content_with_source_fallback(text, file, source_path) do
    """
    [file_contents_tool] NOTE: this file is gitignored and is not present in
    the current worktree. It has been read from the source repo at:
      #{source_path}

    If you want to modify this file, write to its path WITHIN the worktree
    (e.g. `#{file}`). The change will be tracked and copied back to the
    source repo when the worktree is merged after you finalize your response.

    Contents of #{file}:
    Note: Lines are prefixed with `<line_number>:<content_hash>` for identification.
    ```
    #{text}
    ```
    """
  end

  @spec maybe_splice_lines(String.t(), integer() | nil, integer() | nil) :: String.t()
  defp maybe_splice_lines(text, nil, nil), do: text
  defp maybe_splice_lines(text, 1, nil), do: text

  # Line numbers are 1-based, so we adjust accordingly
  defp maybe_splice_lines(text, start_line, end_line) do
    lines = String.split(text, "\n")
    start_index = max(start_line - 1, 0)

    end_index =
      if end_line do
        min(end_line - 1, length(lines) - 1)
      else
        length(lines) - 1
      end

    if start_index <= end_index do
      lines
      |> Enum.slice(start_index..end_index)
      |> Enum.join("\n")
    else
      text
    end
  end

  defp maybe_number_lines(text, true), do: Util.numbered_lines(text, separator: "\t")
  defp maybe_number_lines(text, _), do: text
end

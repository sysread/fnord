defmodule AI.Tools.File.Edit do
  @moduledoc """
  Currently, this module is not used as a tool_call directly. Instead, it is
  used by `AI.Tools.Coder`, the tool directly called by the AI agent. This tool
  is instead used to perform the file edits themselves, after the AI-backed
  tool does the work of identifying the lines to edit and the replacement text.
  """

  @behaviour AI.Tools

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def read_args(args) do
    with {:ok, path} <- AI.Tools.get_arg(args, "path"),
         {:ok, start_line} <- AI.Tools.get_arg(args, "start_line"),
         {:ok, end_line} <- AI.Tools.get_arg(args, "end_line"),
         {:ok, replacement} <- AI.Tools.get_arg(args, "replacement", true) do
      {:ok,
       %{
         "path" => path,
         "start_line" => start_line,
         "end_line" => end_line,
         "replacement" => replacement
       }}
    end
  end

  @impl AI.Tools
  def ui_note_on_request(%{
        "path" => path,
        "start_line" => start_line,
        "end_line" => end_line,
        "replacement" => replacement
      }) do
    {"Editing file #{path}[#{start_line}...#{end_line}]", replacement}
  end

  @impl AI.Tools
  def ui_note_on_result(_, result) do
    {"Changes applied", result}
  end

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "file_edit_tool",
        description: """
        Edit a file within the project source root by replacing a specified range of lines with new text.
        Use the file_contents_tool with the line_numbers parameter to preview or identify the line range to edit.

        - Line numbers are 1-based and inclusive.
        - start_line must be > 0 and <= end_line.
        - end_line must be >= start_line and <= total number of lines in the file.
        - You must produce the exact text to replace the specified lines with, along with any necessary newlines, INCLUDING one at the end of the final line of the replacement text.
        - It is YOUR responsibility to verify the changes after applying them.
        - Use the dry_run option to test your changes before applying them.
        - Line numbers will have changed after the edit. You MUST retrieve the updated file with line numbers if you plan to make additional changes.
        - Use the file_manage_tool to restore the file from backup if the changes are incorrect, then try again.
        """,
        parameters: %{
          type: "object",
          required: ["path", "start_line", "end_line", "replacement"],
          properties: %{
            path: %{
              type: "string",
              description:
                "Path (relative to project root) of the file to operate on (or *source path* for move). Must be within the project source root."
            },
            start_line: %{
              type: "integer",
              description: "The starting line number for the edit (1-based index, inclusive)."
            },
            end_line: %{
              type: "integer",
              description: "The ending line number for the edit (1-based index, inclusive)."
            },
            replacement: %{
              type: "string",
              description:
                "The exact text or code to replace the specified lines with. If you intend to fully replace lines, end with a newline."
            },
            dry_run: %{
              type: "boolean",
              description:
                "If true, the tool will simulate the edit without making any changes. Defaults to false. Returns the updated block, with +/- <context_lines> lines of context around the edit."
            },
            context_lines: %{
              type: "integer",
              description:
                "Number of lines of context to include around the edited block in the dry run output. Defaults to 3."
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(args) do
    with {:ok, path} <- AI.Tools.get_arg(args, "path"),
         {:ok, start_line} <- AI.Tools.get_arg(args, "start_line"),
         {:ok, end_line} <- AI.Tools.get_arg(args, "end_line"),
         {:ok, replacement} <- AI.Tools.get_arg(args, "replacement", true),
         dry_run <- Map.get(args, "dry_run", false),
         context_lines <- Map.get(args, "context_lines", 3),
         {:ok, project} <- Store.get_project(),
         abs_path <- Store.Project.expand_path(path, project),
         :ok <- validate_path(abs_path, project.source_root),
         {:ok, contents} <- File.read(abs_path),
         :ok <- validate_range(contents, start_line, end_line) do
      updated_contents = make_changes(contents, start_line, end_line, replacement)

      if dry_run do
        {:ok, dry_run_preview(contents, updated_contents, start_line, end_line, context_lines)}
      else
        with {:ok, backup} <- backup_file(abs_path),
             {:ok, temp} <- Briefly.create(),
             :ok <- File.cp(path, temp),
             :ok <- File.write(temp, updated_contents),
             :ok <- File.rename(temp, abs_path) do
          {:ok,
           """
           #{path} was modified successfully.
           #{path} is backed up as #{backup}.
           Remember that after making changes, the line numbers within the file have likely changed.
           Use the file_contents_tool with the line_numbers parameter to get the updated line numbers.
           """}
        end
      end
    else
      {:error, :enoent} ->
        {:error,
         "File #{args["path"]} not found. Do you need to create it first with the file_manage_tool?"}

      {:error, reason} ->
        {:error, "Failed to edit file: #{inspect(reason)}"}
    end
  end

  defp validate_path(path, root) do
    cond do
      !Util.path_within_root?(path, root) -> {:error, "not within project root"}
      !File.exists?(path) -> {:error, :enoent}
      true -> :ok
    end
  end

  defp validate_range(file, start_line, end_line) do
    lines = num_lines(file)

    cond do
      start_line < 1 ->
        {:error, "Start line must be greater than or equal to 1."}

      start_line > lines ->
        {:error, "Start line exceeds the number of lines in the file."}

      end_line < start_line ->
        {:error, "End line must be greater than or equal to start line."}

      lines > 0 && end_line > lines ->
        {:error, "End line exceeds the number of lines in the file."}

      true ->
        :ok
    end
  end

  defp num_lines(file) do
    file
    |> String.split("\n", trim: false)
    |> length()
  end

  defp backup_file(file) do
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

  defp dry_run_preview(original, updated, start_line, end_line, context_lines) do
    orig_lines = String.split(original, "\n", trim: false)
    updated_lines = String.split(updated, "\n", trim: false)

    # 1-based to 0-based indices
    start_idx = start_line - 1
    end_idx = end_line - 1

    before_context = max(start_idx - context_lines, 0)

    after_context =
      min(end_idx + context_lines, max(length(orig_lines), length(updated_lines)) - 1)

    # Extract relevant lines from both original and updated
    orig_snippet = Enum.slice(orig_lines, before_context..after_context)
    updated_snippet = Enum.slice(updated_lines, before_context..after_context)

    # Build simple diff output with +/- prefixes
    diff =
      Enum.zip(orig_snippet, updated_snippet)
      |> Enum.map(fn
        {o, u} when o == u -> "  " <> o
        {o, u} -> "- " <> o <> "\n+ " <> u
      end)
      |> Enum.join("\n")

    # Number the snippets for clarity
    orig_snippet =
      orig_snippet
      |> Enum.join("\n")
      |> Util.numbered_lines("|", start_line - context_lines)

    updated_snippet =
      updated_snippet
      |> Enum.join("\n")
      |> Util.numbered_lines("|", start_line - context_lines)

    """
    --- ORIGINAL (with context) ---
    #{orig_snippet}

    --- UPDATED (with context) ---
    #{updated_snippet}

    --- UNIFIED DIFF ---
    #{diff}
    """
  end

  defp make_changes(input, start_line, end_line, replacement) do
    {start_idx, end_idx} = line_range_indices(input, start_line, end_line)
    prefix = binary_part(input, 0, start_idx)
    suffix = binary_part(input, end_idx, byte_size(input) - end_idx)
    prefix <> replacement <> suffix
  end

  defp line_range_indices(subject, start_line, end_line) do
    starts = line_start_offsets(subject)
    total_lines = length(starts)
    s = max(min(start_line, total_lines), 1) - 1
    e = max(min(end_line, total_lines), 1) - 1

    start_idx = Enum.at(starts, s)

    end_idx =
      if e + 1 < total_lines do
        Enum.at(starts, e + 1)
      else
        byte_size(subject)
      end

    {start_idx, end_idx}
  end

  defp line_start_offsets(bin) do
    # All line start offsets, including at EOF if file ends with newline
    offsets = [0]

    offsets =
      bin
      |> :binary.matches("\n")
      |> Enum.reduce(offsets, fn {idx, 1}, acc -> [idx + 1 | acc] end)
      |> Enum.reverse()

    offsets
  end
end

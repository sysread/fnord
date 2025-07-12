defmodule AI.Tools.File.Edit do
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
        Edit a file within the project source root by replacing a range of lines
        with new text. This tool allows you to modify the contents of a file
        directly, specifying the start and end lines to replace with new text.

        Use the file_contents_tool with the line_numbers parameter to identify
        the line range you want to edit.

        The replacement must be a *complete* replacement for the specified
        lines. If it is code, take care to ensure it is valid syntax.

        The modified file will be backed up before editing, allowing you to
        revert changes if needed.
        """,
        parameters: %{
          type: "object",
          required: ["path"],
          properties: %{
            path: %{
              type: "string",
              description:
                "Path (relative to project root) of the file to operate on (or *source path* for move)."
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
              description: "The text or code to replace the specified lines with."
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
         {:ok, project} <- Store.get_project(),
         abs_path <- Store.Project.expand_path(path, project),
         :ok <- validate_path(abs_path, project.source_root),
         {:ok, contents} <- File.read(abs_path),
         :ok <- validate_range(contents, start_line, end_line),
         {:ok, backup} <- backup_file(abs_path),
         {:ok, temp} <- Briefly.create(),
         :ok <- File.cp(path, temp),
         updated_contents <- make_changes(contents, start_line, end_line, replacement),
         :ok <- File.write(temp, updated_contents),
         :ok <- File.rename(temp, abs_path) do
      {:ok, "#{path} was modified successfully. A backup was created at #{backup}."}
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

  defp backup_file(orig, bak_number \\ 0) do
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

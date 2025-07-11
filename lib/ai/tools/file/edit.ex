defmodule AI.Tools.File.Edit do
  @behaviour AI.Tools

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

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
         {:ok, replacement} <- AI.Tools.get_arg(args, "replacement"),
         {:ok, project} <- Store.get_project(),
         abs_path <- Store.Project.expand_path(path, project),
         true <- Util.path_within_root?(abs_path, project.source_root),
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
      {:error, posix, msg} -> {:error, "Failed to edit file (#{inspect(posix)}): #{msg}"}
      {:error, reason} -> {:error, "Failed to edit file: #{inspect(reason)}"}
    end
  end

  defp num_lines(file) do
    file
    |> String.split("\n", trim: false)
    |> length()
  end

  defp validate_range(file, start_line, end_line) do
    cond do
      start_line < 1 ->
        {:error, "Start line must be greater than or equal to 1."}

      end_line < start_line ->
        {:error, "End line must be greater than or equal to start line."}

      end_line > num_lines(file) ->
        {:error, "End line exceeds the number of lines in the file."}

      true ->
        :ok
    end
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

  defp make_changes(contents, start_line, end_line, replacement) do
    lines = String.split(contents, "\n", trim: false)
    pre = Enum.slice(lines, 0, start_line - 1)
    post = Enum.slice(lines, end_line, length(lines) - end_line)
    out = pre ++ String.split(replacement, "\n", trim: false) ++ post
    Enum.join(out, "\n")
  end
end

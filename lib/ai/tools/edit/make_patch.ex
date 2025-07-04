defmodule AI.Tools.Edit.MakePatch do
  @behaviour AI.Tools

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def ui_note_on_request(%{
        "file" => file,
        "start_line" => start_line,
        "end_line" => end_line,
        "new_code" => new_code
      }) do
    {"Building patch for #{file}:#{start_line}-#{end_line}",
     """
     ```
     #{new_code}
     ```
     """}
  end

  @impl AI.Tools
  def ui_note_on_result(
        %{
          "file" => file,
          "start_line" => start_line,
          "end_line" => end_line
        },
        result
      ) do
    {"Patch for #{file}:#{start_line}-#{end_line}", result}
  end

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "make_patch",
        description: """
        This tool builds a patch file that can be used to apply changes to a
        file. It accepts a "hunk" (a contiguous section of code defined by a
        file path, start line, and end line) and a block of code to replace the
        *entire hunk in full*.

        Once you have created a patch, you can apply it to the file using
        apply_patch tool.
        """,
        parameters: %{
          type: "object",
          required: ["file", "start_line", "end_line", "new_code"],
          properties: %{
            file: %{
              type: "string",
              description: """
              The file to edit. It must be the complete path provided by the
              file_search_tool or file_list_tool.
              """
            },
            start_line: %{
              type: "integer",
              description: """
              The starting line number of the code hunk to edit. This is inclusive,
              meaning the line at this number will be included in the edit.
              """
            },
            end_line: %{
              type: "integer",
              description: """
              The ending line number of the code hunk to edit. This is inclusive,
              meaning the line at this number will be included in the edit.
              """
            },
            new_code: %{
              type: "string",
              description: """
              The complete replacement code that will replace the entire hunk
              specified by the start and end line numbers. This should include
              all lines of code you want to write, replacing the existing lines
              in the specified range. Pay special attention to indentation and
              syntax, as the new code will completely replace the old code,
              exactly as provided.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(%{
        "file" => file,
        "start_line" => start_line,
        "end_line" => end_line,
        "new_code" => new_code
      }) do
    with {:ok, contents} <- AI.Tools.get_file_contents(file),
         {start_line, ""} <- Integer.parse(start_line),
         {end_line, ""} <- Integer.parse(end_line),
         {:ok, new_contents} <- update_code(contents, start_line, end_line, new_code),
         {:ok, orig, dest} <- make_temp_files(new_contents) do
      make_patch(orig, dest)
    end
  end

  defp make_patch(orig, temp) do
    System.cmd("diff", ["-u", orig, temp])
    |> case do
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, "Failed to build patch: #{output}"}
    end
  end

  defp make_temp_files(contents) do
    with {:ok, path1} <- Briefly.create(),
         {:ok, path2} <- Briefly.create(),
         :ok <- File.write(path1, contents),
         :ok <- File.write(path1, contents) do
      {:ok, path1, path2}
    end
  end

  defp update_code(contents, start_line, end_line, new_code) do
    lines = String.split(contents, "\n")
    pre = Enum.take(lines, start_line - 1)
    post = Enum.drop(lines, end_line)
    {:ok, Enum.join([pre, new_code, post], "\n")}
  end
end

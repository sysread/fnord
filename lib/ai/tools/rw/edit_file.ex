defmodule AI.Tools.RW.EditFile do
  @behaviour AI.Tools

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def read_args(args), do: {:ok, args}

  @impl AI.Tools
  def ui_note_on_request(args) do
    {"Editing file", summarize_changes(args)}
  end

  @impl AI.Tools
  def ui_note_on_result(args, result) do
    summary = summarize_changes(args)

    with {:ok, data} <- Jason.decode(result),
         {:ok, diff} <- Map.fetch(data, "diff") do
      {"File edited",
       """
       #{summary}
       -----
       #{diff}
       """}
    end
  end

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "edit_file",
        description: """
        Apply one or more line-oriented regex replacements to a file.
        If dry_run=true, no files are changed: a diff is returned instead.
        """,
        parameters: %{
          type: "object",
          required: ["file", "edits"],
          properties: %{
            dry_run: %{
              type: "boolean",
              description: "If true, do not write files; return only the diff.",
              default: false
            },
            file: %{
              type: "string",
              description: "Path to target file, relative to project root."
            },
            edits: %{
              type: "array",
              description: "List of regex edits to apply, in order.",
              items: %{
                type: "object",
                required: ["pattern", "replacement"],
                properties: %{
                  pattern: %{
                    type: "string",
                    description: "Regex to match (single line)."
                  },
                  replacement: %{
                    type: "string",
                    description: "Replacement text; may include capture groups."
                  },
                  line_start: %{
                    type: "integer",
                    description: "Optional 1-based start line for matching."
                  },
                  line_end: %{
                    type: "integer",
                    description: "Optional 1-based end line for matching."
                  },
                  flags: %{
                    type: "string",
                    description: "Optional sed flags, e.g. 'g' or 'i'."
                  }
                }
              }
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(opts) do
    dry_run = Map.get(opts, "dry_run", false)

    with {:ok, rel} <- Map.fetch(opts, "file"),
         {:ok, edits} <- Map.fetch(opts, "edits"),
         {:ok, root} <- get_root(),
         {:ok, abs_path} <- Util.find_file_within_root(rel, root),
         {:ok, workfile} <- make_workfile(abs_path),
         :ok <- perform_edits(workfile, edits),
         {:ok, diff} <- get_diff(abs_path, workfile),
         :ok <- apply_changes(abs_path, workfile, dry_run, diff) do
      {:ok,
       %{
         "file" => rel,
         "dry_run" => dry_run,
         "diff" => diff
       }}
    end
  end

  @confirm_changes_override :confirm_changes_override
  def override_confirm_changes(value) do
    Process.put(@confirm_changes_override, value)
  end

  @spec get_root() :: {:ok, binary} | {:error, File.posix()}
  defp get_root do
    with {:ok, project} <- Store.get_project() do
      {:ok, project.source_root}
    else
      _ -> File.cwd()
    end
  end

  @spec apply_changes(binary, binary, boolean, binary) :: :ok | {:error, binary}
  defp apply_changes(path, temp, dry_run?, diff)
  defp apply_changes(_path, _temp, true, _diff), do: :ok

  defp apply_changes(path, temp, false, diff) do
    confirmed? =
      if Process.get(@confirm_changes_override, false) do
        true
      else
        confirm_changes?(path, diff)
      end

    if confirmed? do
      File.cp(temp, path)
    else
      {:error, "User rejected patch"}
    end
  end

  defp confirm_changes?(file, diff) do
    IO.puts(:stderr, """
    Fnord would like to make the following changes to #{file}:

    ```diff
    #{diff}
    ```
    """)

    UI.confirm("Apply these changes?")
  end

  @spec get_diff(binary, binary) :: {:ok, binary} | {:error, binary}
  defp get_diff(path, tmp) do
    System.cmd("diff", ["-u", path, tmp], stderr_to_stdout: true)
    |> case do
      {"", 0} -> {:ok, "No changes"}
      {out, 1} -> {:ok, out}
      {err, _} -> {:error, "diff failed: #{err}"}
    end
  end

  @spec perform_edits(binary, [list(map)]) :: :ok | {:error, binary}
  defp perform_edits(path, edits) do
    edits
    |> Enum.reduce_while(:ok, fn edit, acc ->
      case Sed.run(path, edit) do
        :ok -> {:cont, acc}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec make_workfile(binary) :: {:ok, binary} | {:error, any}
  defp make_workfile(path) do
    with {:ok, tmp} <- Briefly.create(),
         :ok <- File.cp(path, tmp) do
      {:ok, tmp}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp summarize_changes(%{"file" => file, "edits" => edits, "dry_run" => dry_run?}) do
    edit_summary =
      edits
      |> Enum.map(fn %{"pattern" => p, "replacement" => r} = edit ->
        start_line = Map.get(edit, "line_start", "")
        end_line = Map.get(edit, "line_end", "")

        start_line =
          if start_line == "" && end_line != "" do
            "1"
          else
            start_line
          end

        """
        Pattern: #{p}
        Replacement: #{r}
        Line range: #{if start_line != "" do
          "#{start_line}#{if end_line != "", do: "-#{end_line}", else: ""}"
        else
          "all lines"
        end}
        """
      end)
      |> Enum.join("\n-----\n")

    """
    File: #{file}
    Dry run? #{inspect(dry_run?)}
    Changes:
    #{edit_summary}
    """
  end
end

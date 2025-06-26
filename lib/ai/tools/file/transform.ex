defmodule AI.Tools.File.Transform do
  @behaviour AI.Tools

  @impl AI.Tools
  def ui_note_on_request(%{"file" => file}), do: {"Transforming file", file}

  @impl AI.Tools
  def ui_note_on_result(%{"file" => file, "dry_run" => true}, _), do: {"Dry run complete", file}
  def ui_note_on_result(%{"file" => file}, _), do: {"Applied edits to", file}

  @impl AI.Tools
  def spec() do
    %{
      type: "function",
      function: %{
        name: "file_transform_tool",
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
  def read_args(args) do
    # merge default dry_run = false
    args = Map.put_new(args, "dry_run", false)

    with {:ok, file} <- fetch_arg(args, "file"),
         {:ok, edits} <- fetch_arg(args, "edits") do
      {:ok, %{"file" => file, "edits" => edits, "dry_run" => args["dry_run"]}}
    end
  end

  @impl AI.Tools
  def call(opts) do
    project = Store.get_project()

    with {:ok, rel} <- Map.fetch(opts, "file"),
         {:ok, edits} <- Map.fetch(opts, "edits"),
         {:ok, dry_run} <- Map.fetch(opts, "dry_run"),
         {:ok, abs_path} <- Store.Project.find_file(project, rel),
         {:ok, workfile} <- make_workfile(abs_path),
         :ok <- perform_edits(workfile, edits),
         {:ok, diff} <- get_diff(abs_path, workfile),
         :ok <- apply_changes(abs_path, workfile, dry_run) do
      {:ok,
       %{
         "file" => rel,
         "dry_run" => dry_run,
         "diff" => diff
       }}
    end
  end

  @spec fetch_arg(map, binary) ::
          {:ok, binary}
          | {:error, :invalid_argument, binary}
          | {:error, :missing_argument, binary}
  defp fetch_arg(map, key) do
    case Map.fetch(map, key) do
      {:ok, ""} -> {:error, :invalid_argument, key}
      :error -> {:error, :missing_argument, key}
      {:ok, val} -> {:ok, val}
    end
  end

  @spec apply_changes(binary, binary, boolean) :: :ok | {:error, binary}
  defp apply_changes(_path, _temp, true), do: :ok
  defp apply_changes(path, temp, false), do: File.cp(temp, path)

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
      case run_sed(path, edit) do
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

  @spec run_sed(binary, map) :: :ok | {:error, binary}
  defp run_sed(file, %{"pattern" => pat, "replacement" => rep} = edit) do
    ls = Map.get(edit, "line_start", "")
    le = Map.get(edit, "line_end", "")
    flags = Map.get(edit, "flags", "")

    range =
      case {ls, le} do
        {l, ""} when is_integer(l) -> "#{l},$"
        {"", l} when is_integer(l) -> "1,#{l}"
        {l1, l2} when is_integer(l1) and is_integer(l2) -> "#{l1},#{l2}"
        _ -> ""
      end

    args = ["-E", "-i", "", "#{range}s/#{pat}/#{rep}/#{flags}", file]

    case System.cmd("sed", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {err, _} -> {:error, "sed failed: #{err}"}
    end
  end
end

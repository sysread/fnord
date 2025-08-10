defmodule AI.Tools.File.Manage do
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: true

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def ui_note_on_request(%{"operation" => "create", "path" => path}), do: {"Creating file", path}
  def ui_note_on_request(%{"operation" => "delete", "path" => path}), do: {"Deleting file", path}

  def ui_note_on_request(%{"operation" => "move", "path" => path, "destination_path" => dest}) do
    {"Moving file", "#{path} -> #{dest}"}
  end

  def ui_note_on_request(_), do: nil

  @impl AI.Tools
  def ui_note_on_result(%{"operation" => "create", "path" => path}, {:ok, _}) do
    {"File created", path}
  end

  def ui_note_on_result(%{"operation" => "delete", "path" => path}, {:ok, _}) do
    {"File deleted", path}
  end

  def ui_note_on_result(
        %{"operation" => "move", "path" => path, "destination_path" => dest},
        {:ok, _}
      ) do
    {"File moved", "#{path} -> #{dest}"}
  end

  def ui_note_on_result(_args, {:error, reason}), do: {"File operation error", to_string(reason)}
  def ui_note_on_result(_args, result), do: {"File operation result", result}

  @impl AI.Tools
  def read_args(%{"operation" => "create"} = args) do
    with {:ok, path} <- AI.Tools.get_arg(args, "path") do
      {:ok,
       %{
         "operation" => "create",
         "path" => path,
         "is_directory" => Map.get(args, "is_directory", false)
       }}
    end
  end

  def read_args(%{"operation" => "delete"} = args) do
    with {:ok, path} <- AI.Tools.get_arg(args, "path") do
      {:ok,
       %{
         "operation" => "delete",
         "path" => path,
         "is_directory" => Map.get(args, "is_directory", false)
       }}
    end
  end

  def read_args(%{"operation" => "move"} = args) do
    with {:ok, path} <- AI.Tools.get_arg(args, "path"),
         {:ok, dest_path} <- AI.Tools.get_arg(args, "destination_path") do
      {:ok,
       %{
         "operation" => "move",
         "path" => path,
         "destination_path" => dest_path
       }}
    end
  end

  def read_args(%{"operation" => _}) do
    {:error, :invalid_argument, "operation"}
  end

  def read_args(_) do
    {:error, :missing_argument, "operation"}
  end

  @impl AI.Tools
  def spec do
    %{
      type: "function",
      function: %{
        name: "file_manage_tool",
        description: """
        Create, delete, or move files within the project source root. This does
        NOT allow you to edit files directly. It only allows you to perform
        basic file operations like creating, deleting, or moving/renaming files
        and directories.
        """,
        parameters: %{
          type: "object",
          required: ["operation", "path"],
          properties: %{
            operation: %{
              type: "string",
              enum: ["create", "delete", "move"],
              description: "The operation to perform: create, delete, or move."
            },
            path: %{
              type: "string",
              description: """
              Path (relative to project root) of the file to operate on (or *source path* for move).
              """
            },
            destination_path: %{
              type: "string",
              description: "Required for move: the new path (relative to project root)."
            },
            is_directory: %{
              type: "boolean",
              description: """
              If true, treat the path as a directory (for create or delete operations).
              Required to delete a directory.
              """
            },
            initial_contents: %{
              type: "string",
              description: """
              ONLY applicable when `operation` is `create` and `is_directory` is false.
              Initial contents of the file to create. If not provided, an empty file will be created.
              """
            }
          }
        }
      }
    }
  end

  @impl AI.Tools
  def call(%{"operation" => op, "path" => path} = args) do
    with {:ok, project} <- Store.get_project(),
         abs_src <- Store.Project.expand_path(path, project),
         is_directory? <- Map.get(args, "is_directory", false),
         initial_contents <- Map.get(args, "initial_contents", ""),
         :ok <- validate_path(project, path) do
      case op do
        "create" -> create_path(path, abs_src, is_directory?, initial_contents)
        "delete" -> delete_path(path, abs_src, is_directory?)
        "move" -> move_path(project, path, abs_src, args["destination_path"])
        _ -> {:error, :invalid_argument, "operation"}
      end
    end
  end

  defp validate_path(project, path) do
    if Util.path_within_root?(path, project.source_root) do
      :ok
    else
      {:error, "Path escapes project root!"}
    end
  end

  defp create_path(path, abs_path, true, _initial_contents) do
    if File.exists?(abs_path) do
      {:error, "Path already exists: #{path}"}
    else
      abs_path
      |> Path.dirname()
      |> File.mkdir_p()
      |> case do
        :ok -> {:ok, "Created directory: #{path}"}
        {:error, reason} -> {:error, "Failed to create directory #{path}: #{inspect(reason)}"}
      end
    end
  end

  defp create_path(path, abs_path, false, initial_contents) do
    if File.exists?(abs_path) do
      {:error, "Path already exists: #{path}"}
    else
      abs_path |> Path.dirname() |> File.mkdir_p!()

      case File.write(abs_path, initial_contents) do
        :ok -> {:ok, "Created file: #{path}"}
        {:error, reason} -> {:error, "Failed to create file #{path}: #{inspect(reason)}"}
      end
    end
  end

  defp delete_path(path, abs_path, true) do
    if File.exists?(abs_path) do
      abs_path
      |> File.rm_rf()
      |> case do
        {:ok, _} ->
          {:ok, "Deleted directory: #{path}"}

        {:error, _posix, reason} ->
          {:error, "Failed to delete directory #{path}: #{inspect(reason)}"}
      end
    else
      {:error, "File does not exist: #{path}"}
    end
  end

  defp delete_path(path, abs_path, false) do
    if File.exists?(abs_path) do
      abs_path
      |> File.rm()
      |> case do
        :ok -> {:ok, "Deleted file: #{path}"}
        {:error, reason} -> {:error, "Failed to delete file #{path}: #{inspect(reason)}"}
      end
    else
      {:error, "File does not exist: #{path}"}
    end
  end

  defp move_path(project, path, abs_path, dest_path) do
    dest =
      dest_path
      |> to_string()
      |> Store.Project.expand_path(project)

    cond do
      not Util.path_within_root?(dest, project.source_root) ->
        {:error, "Destination path escapes project root."}

      not File.exists?(abs_path) ->
        {:error, "Source path does not exist: #{path}"}

      File.exists?(dest) ->
        {:error, "Destination path already exists: #{dest_path}"}

      true ->
        File.mkdir_p!(Path.dirname(dest))

        case File.rename(abs_path, dest) do
          :ok ->
            {:ok, "Moved #{path} -> #{dest_path}"}

          {:error, reason} ->
            {:error, "Failed to move (#{path} to #{dest_path}): #{inspect(reason)}"}
        end
    end
  end
end

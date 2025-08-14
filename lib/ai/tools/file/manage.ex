defmodule AI.Tools.File.Manage do
  @behaviour AI.Tools

  @impl AI.Tools
  def async?, do: true

  @impl AI.Tools
  def is_available?, do: true

  @impl AI.Tools
  def ui_note_on_request(%{"operation" => "create", "is_directory" => true, "path" => path}) do
    {"Creating dir", path}
  end

  def ui_note_on_request(%{"operation" => "create", "path" => path}) do
    {"Creating file", path}
  end

  def ui_note_on_request(%{"operation" => "replace", "path" => path}) do
    {"Overwriting file", path}
  end

  def ui_note_on_request(%{"operation" => "delete", "is_directory" => true, "path" => path}) do
    {"Deleting dir", path}
  end

  def ui_note_on_request(%{"operation" => "delete", "path" => path}) do
    {"Deleting file", path}
  end

  def ui_note_on_request(%{"operation" => "move", "path" => path, "destination_path" => dest}) do
    {"Moving file", "#{path} -> #{dest}"}
  end

  def ui_note_on_request(_), do: nil

  @impl AI.Tools
  def ui_note_on_result(%{"operation" => "create", "is_directory" => true, "path" => path}, _) do
    {"Dir created", path}
  end

  def ui_note_on_result(%{"operation" => "create", "path" => path}, _) do
    {"File created", path}
  end

  def ui_note_on_result(%{"operation" => "replace", "path" => path}, _) do
    {"File overwritten", path}
  end

  def ui_note_on_result(%{"operation" => "delete", "is_directory" => true, "path" => path}, _) do
    {"Dir deleted", path}
  end

  def ui_note_on_result(%{"operation" => "delete", "path" => path}, _) do
    {"File deleted", path}
  end

  def ui_note_on_result(%{"operation" => "move", "path" => path, "destination_path" => dest}, _) do
    {"File moved", "#{path} -> #{dest}"}
  end

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

  def read_args(%{"operation" => "replace"} = args) do
    with {:ok, path} <- AI.Tools.get_arg(args, "path"),
         {:ok, file_content} <- AI.Tools.get_arg(args, "file_content") do
      {:ok,
       %{
         "operation" => "replace",
         "path" => path,
         "file_content" => file_content
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
              enum: ["create", "replace", "delete", "move"],
              description: "The operation to perform: create, replace, delete, or move."
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
            file_content: %{
              type: "string",
              description: """
              Not applicable to `delete` or `move` operations.
              Not application if `is_directory` is true.

              For `create` operations, this is the content to write to the file.
              If not provided, an empty file will be created.

              For `replace` operations, this is the new content to write, completely replacing the file's contents.
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
         file_content <- Map.get(args, "file_content", ""),
         :ok <- validate_path(project, path) do
      case op do
        "create" -> create_path(path, abs_src, is_directory?, file_content)
        "replace" -> replace_path(path, abs_src, file_content)
        "delete" -> delete_path(path, abs_src, is_directory?)
        "move" -> move_path(project, path, abs_src, args["destination_path"])
        other -> {:error, :invalid_argument, "operation ('#{other}' not supported)"}
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

  defp create_path(path, abs_path, true, _file_content) do
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

  defp create_path(path, abs_path, false, file_content) do
    if File.exists?(abs_path) do
      {:error, "Path already exists: #{path}"}
    else
      abs_path |> Path.dirname() |> File.mkdir_p!()

      case File.write(abs_path, file_content) do
        :ok -> {:ok, "Created file: #{path}"}
        {:error, reason} -> {:error, "Failed to create file #{path}: #{inspect(reason)}"}
      end
    end
  end

  defp replace_path(path, abs_path, file_content) do
    cond do
      not File.exists?(abs_path) ->
        {:error, "File does not exist: #{path}"}

      File.dir?(abs_path) ->
        {:error, "Cannot replace a directory with a file: #{path}"}

      true ->
        abs_path
        |> File.write(file_content)
        |> case do
          :ok -> {:ok, "Replaced file contents: #{path}"}
          {:error, reason} -> {:error, "Failed to replace file #{path}: #{inspect(reason)}"}
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

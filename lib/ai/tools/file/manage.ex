defmodule AI.Tools.File.Manage do
  @moduledoc """
  Create, delete, and move or rename files _safely_ within the project's source root.
  This tool prevents any path escaping tricks (including symlinks and `..`)
  and will not overwrite files unless you extend it to do so.

  ## Supported Operations

    - `"create"`: Create an empty file at the supplied relative path.
    - `"delete"`: Delete the specified file.
    - `"move"`: Move (rename) the source path to a new destination path.

  ## Safety & Security

    - All file paths are strictly validated: no operation can escape the source root.
    - Symlinks are resolved and validated using `Util.path_within_root?/2`.
    - Will not overwrite files: "create" fails if the file exists; "move" fails if the target exists.
    - Parent directories will be created as needed for "create" and "move".
    - Clean error messages for invalid arguments or OS failures.
  """

  @behaviour AI.Tools

  @impl AI.Tools
  def is_available?, do: true

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
              description:
                "Path (relative to project root) of the file to operate on (or *source path* for move)."
            },
            destination_path: %{
              type: "string",
              description: "Required for move: the new path (relative to project root)."
            },
            is_directory: %{
              type: "boolean",
              description:
                "If true, treat the path as a directory (for create or delete operations). Required to delete a directory."
            }
          }
        }
      }
    }
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

  def read_args(%{"operation" => _}) do
    {:error, :invalid_argument, "operation"}
  end

  def read_args(_) do
    {:error, :missing_argument, "operation"}
  end

  @impl AI.Tools
  def call(%{"operation" => op, "path" => path} = args) do
    with {:ok, project} <- Store.get_project(),
         abs_src <- Store.Project.expand_path(path, project),
         is_directory <- Map.get(args, "is_directory", false),
         true <- Util.path_within_root?(abs_src, project.source_root) do
      case op do
        "create" ->
          if File.exists?(abs_src) do
            {:error, "Path already exists: #{path}"}
          else
            if is_directory do
              File.mkdir_p(Path.dirname(abs_src))
              |> case do
                :ok ->
                  {:ok, "Created directory: #{path}"}

                {:error, reason} ->
                  {:error, "Failed to create directory #{path}: #{inspect(reason)}"}
              end
            else
              File.mkdir_p!(Path.dirname(abs_src))

              case File.write(abs_src, "") do
                :ok -> {:ok, "Created file: #{path}"}
                {:error, reason} -> {:error, "Failed to create file #{path}: #{inspect(reason)}"}
              end
            end
          end

        "delete" ->
          if File.exists?(abs_src) do
            if is_directory do
              case File.rm_rf(abs_src) do
                {:ok, _} ->
                  {:ok, "Deleted directory: #{path}"}

                {:error, posix, reason} ->
                  {:error,
                   "Failed to delete directory #{path}: [#{inspect(posix)}] #{inspect(reason)}"}
              end
            else
              case File.rm(abs_src) do
                :ok -> {:ok, "Deleted file: #{path}"}
                {:error, reason} -> {:error, "Failed to delete file #{path}: #{inspect(reason)}"}
              end
            end
          else
            {:error, "File does not exist: #{path}"}
          end

        "move" ->
          dest =
            args["destination_path"]
            |> to_string()
            |> Store.Project.expand_path(project)

          cond do
            not Util.path_within_root?(dest, project.source_root) ->
              {:error, "Destination path escapes project root."}

            not File.exists?(abs_src) ->
              {:error, "Source path does not exist: #{path}"}

            File.exists?(dest) ->
              {:error, "Destination path already exists: #{args["destination_path"]}"}

            true ->
              File.mkdir_p!(Path.dirname(dest))

              case File.rename(abs_src, dest) do
                :ok ->
                  {:ok, "Moved #{path} -> #{args["destination_path"]}"}

                {:error, reason} ->
                  {:error,
                   "Failed to move (#{path} to #{args["destination_path"]}): #{inspect(reason)}"}
              end
          end

        _ ->
          {:error, :invalid_argument, "operation"}
      end
    else
      false -> {:error, "Path escapes project root!"}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  @impl AI.Tools
  def ui_note_on_request(%{"operation" => "create", "path" => path}), do: {"Creating file", path}
  def ui_note_on_request(%{"operation" => "delete", "path" => path}), do: {"Deleting file", path}

  def ui_note_on_request(%{"operation" => "move", "path" => path, "destination_path" => dest}),
    do: {"Moving file", "#{path} -> #{dest}"}

  def ui_note_on_request(_), do: nil

  @impl AI.Tools
  def ui_note_on_result(%{"operation" => "create", "path" => path}, {:ok, _}),
    do: {"File created", path}

  def ui_note_on_result(%{"operation" => "delete", "path" => path}, {:ok, _}),
    do: {"File deleted", path}

  def ui_note_on_result(
        %{"operation" => "move", "path" => path, "destination_path" => dest},
        {:ok, _}
      ),
      do: {"File moved", "#{path} -> #{dest}"}

  def ui_note_on_result(_args, {:error, reason}), do: {"File operation error", to_string(reason)}
  def ui_note_on_result(_args, result), do: {"File operation result", inspect(result)}
end

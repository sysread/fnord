defmodule Store.Project do
  defstruct [
    :name,
    :store_path,
    :source_root,
    :exclude,
    :conversation_dir,
    :notes_dir,
    :exclude_cache
  ]

  @type t :: %__MODULE__{}

  @conversation_dir "conversations"
  @notes_dir "notes"

  @spec new(String.t(), String.t()) :: t()
  def new(project_name, store_path) do
    settings = Settings.new() |> Settings.get(project_name, %{})
    exclude = Map.get(settings, "exclude", [])
    root = Map.get(settings, "root", nil)

    %__MODULE__{
      name: project_name,
      store_path: store_path,
      source_root: root,
      exclude: exclude,
      conversation_dir: Path.join(store_path, @conversation_dir),
      notes_dir: Path.join(store_path, @notes_dir)
    }
  end

  @spec save_settings(t(), String.t() | nil, String.t() | nil) :: t()
  def save_settings(project, source_root \\ nil, exclude \\ nil) do
    root =
      case source_root do
        nil -> project.source_root || raise("project root is required")
        _ -> Path.expand(source_root)
      end

    exclude =
      case exclude do
        nil -> project.exclude || []
        [] -> project.exclude || []
        exclude -> exclude |> Enum.map(&relative_to!(&1, root))
      end
      |> Enum.filter(fn exclude ->
        exclude
        |> Path.expand(root)
        |> File.exists?()
        |> case do
          true ->
            true

          false ->
            UI.warn("Removing non-existent path from project exclude list: #{exclude}")
            false
        end
      end)

    Settings.new()
    |> Settings.set(project.name, %{
      "root" => root,
      "exclude" => exclude
    })

    new(project.name, project.store_path)
  end

  @spec create(t()) :: t()
  def create(project) do
    project.store_path |> File.mkdir_p!()
    project.store_path |> Path.join("conversations") |> File.mkdir_p!()
    File.touch!(project.store_path |> Path.join("notes.md"))
    project
  end

  @spec delete(t()) :: :ok
  def delete(project) do
    # Delete indexed files
    project.store_path
    |> Path.join("*/metadata.json")
    |> Path.wildcard()
    |> Enum.map(&Path.dirname/1)
    |> Enum.each(fn path -> File.rm_rf!(path) end)
  end

  @spec torch(t()) :: :ok
  def torch(project) do
    # Delete entire directory
    File.rm_rf!(project.store_path)

    # Remove from settings
    Settings.new() |> Settings.delete(project.name)

    :ok
  end

  @spec make_default_for_session(t()) :: t
  def make_default_for_session(project) do
    Application.put_env(:fnord, :project, project.name)
    project
  end

  # ----------------------------------------------------------------------------
  # Entries
  # ----------------------------------------------------------------------------
  @spec has_index?(t()) :: boolean()
  def has_index?(project) do
    glob = Path.join(project.store_path, "**/embeddings.json")

    System.cmd("bash", ["-c", ~s[compgen -G "$1" > /dev/null], "--", glob])
    |> case do
      {_, 0} -> true
      _ -> false
    end
  end

  @spec find_entry(t(), String.t()) :: {:ok, Store.Project.Entry.t()} | {:error, atom()}
  def find_entry(project, path) do
    with {:ok, resolved} <- find_file(project, path) do
      {:ok, Store.Project.Entry.new_from_file_path(project, resolved)}
    end
  end

  @spec find_file(t(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def find_file(project, path) do
    [
      &find_abs_file_root/2,
      &find_abs_file_project/2,
      &find_rel_file_project/2,
      &find_file_project/2
    ]
    |> Enum.find_value(fn f ->
      with {:ok, path} <- f.(project, path) do
        {:ok, path}
      else
        _ -> false
      end
    end)
    |> case do
      {:ok, path} -> {:ok, path}
      _ -> {:error, :not_found}
    end
  end

  @spec expand_path(String.t(), t()) :: String.t()
  def expand_path(path, %Store.Project{} = project) do
    Path.expand(path, project.source_root)
  end

  @spec relative_path(String.t(), t()) :: String.t()
  def relative_path(path, project) do
    path
    |> expand_path(project)
    |> Path.relative_to(project.source_root)
  end

  @spec find_path_in_source_root(Store.Project.t(), String.t()) ::
          {:ok, :dir | :file | :not_found, String.t()}
  def find_path_in_source_root(project, path) do
    path = expand_path(path, project)

    cond do
      File.dir?(path) -> {:ok, :dir, path}
      File.regular?(path) -> {:ok, :file, path}
      true -> {:ok, :not_found, path}
    end
  end

  @spec exists_in_store?(t()) :: boolean()
  def exists_in_store?(project) do
    path = project.store_path
    files = Path.wildcard(Path.join(path, "*"))

    cond do
      !File.dir?(path) -> false
      # There was a bug at one point where store files were deleted but not the
      # directory itself. This check is to ensure that the directory is empty.
      Enum.empty?(files) -> false
      true -> true
    end
  end

  @spec stored_files(t()) :: Enumerable.t()
  def stored_files(project) do
    # Start with the path to the project in the store
    project.store_path
    # Each entry is a dir that contains metadata.json; this step ignores things
    # like the conversations directory.
    |> Path.join("*/metadata.json")
    # Expand the glob
    |> Path.wildcard()
    # Strip metadata.json from the each listing, leaving the directory path for
    # the individual entry.
    |> Stream.map(&Path.dirname/1)
    # Create an Entry for each directory.
    |> Stream.map(&Store.Project.Entry.new_from_entry_path(project, &1))
  end

  @spec source_files(t()) :: {t, Enumerable.t()}
  def source_files(project) do
    {project, excluded_paths} = excluded_paths(project)

    files =
      project
      |> list_all_files()
      |> Stream.filter(&(!is_hidden?(&1)))
      |> Stream.filter(&(!MapSet.member?(excluded_paths, &1)))
      |> Stream.filter(&is_text?(&1, project))
      |> Stream.map(&Store.Project.Entry.new_from_file_path(project, &1))

    {project, files}
  end

  @spec delete_missing_files(t()) :: {t, Enumerable.t()}
  def delete_missing_files(project) do
    {project, excluded_paths} = excluded_paths(project)

    entries =
      project
      |> stored_files()
      |> Stream.filter(&(MapSet.member?(excluded_paths, &1.file) || !File.exists?(&1.file)))
      |> Stream.map(fn entry ->
        Store.Project.Entry.delete(entry)
        entry
      end)

    {project, entries}
  end

  # -----------------------------------------------------------------------------
  # Conversations
  # -----------------------------------------------------------------------------
  @spec conversations(t()) :: [Store.Project.Conversation.t()]
  def conversations(project) do
    Store.Project.Conversation.list(project.store_path)
  end

  # -----------------------------------------------------------------------------
  # Private functions
  # -----------------------------------------------------------------------------
  defp list_all_files(project) do
    args = ["-c", "(find #{project.source_root} -type f || true) | sort"]

    case System.cmd("sh", args, stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Stream.filter(&(!String.ends_with?(&1, ": Permission denied")))
        |> Stream.map(&Path.absname(&1, project.source_root))

      {error_output, _} ->
        raise "find command failed: #{error_output}"
    end
  end

  defp is_hidden?(path) do
    cond do
      String.ends_with?(path, ".github") -> false
      String.starts_with?(path, ".") -> true
      String.contains?(path, "/.") -> true
      true -> false
    end
  end

  defp is_text?(file_path, project) do
    try do
      file_path
      |> Path.expand(project.source_root)
      |> File.stream!(1024)
      |> Enum.reduce_while(true, fn chunk, _acc ->
        if String.valid?(chunk) do
          {:cont, true}
        else
          {:halt, false}
        end
      end)
    rescue
      _ -> false
    end
  end

  defp excluded_paths(%{exclude_cache: nil} = project) do
    user_excluded =
      if is_nil(project.exclude) do
        MapSet.new()
      else
        project.exclude
        |> Enum.flat_map(fn exclude ->
          case find_path_in_source_root(project, exclude) do
            # If it's a directory, exclude all files in that directory
            {:ok, :dir, path} -> Path.wildcard(Path.join(path, "**/*"), match_dot: true)
            # If it's a single file, exclude just that file
            {:ok, :file, path} -> [path]
            # Otherwise, treat it as a glob
            _ -> Path.wildcard(exclude, match_dot: true)
          end
        end)
        # Filter out directories and non-existent files
        |> Enum.filter(&File.regular?/1)
        # Convert everything to absolute paths
        |> Enum.map(&Path.absname/1)
        # Convert to a MapSet for faster lookups
        |> MapSet.new()
      end

    excluded =
      with {:ok, git_ignored_files} <- Git.ignored_files(project.source_root) do
        MapSet.union(user_excluded, git_ignored_files)
      else
        {:error, _} -> user_excluded
      end

    {%{project | exclude_cache: excluded}, excluded}
  end

  defp excluded_paths(%{exclude_cache: excluded} = project) do
    {project, excluded}
  end

  defp relative_to!(path, cwd) do
    with {:ok, path} <- Path.safe_relative(path, cwd) do
      path
    else
      :error -> raise("Error: unable to calculate relative path for #{path} from #{cwd}")
    end
  end

  defp find_abs_file_root(_project, path) do
    if String.starts_with?(path, "/") && File.exists?(path) do
      {:ok, path}
    else
      {:error, :not_found}
    end
  end

  defp find_abs_file_project(project, path) do
    if String.starts_with?(path, "/") do
      path =
        Path.join(project.source_root, path)
        |> Path.expand(project.source_root)

      if File.exists?(path) do
        {:ok, path}
      else
        {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  defp find_rel_file_project(project, path) do
    path = expand_path(path, project)

    if File.exists?(path) do
      {:ok, path}
    else
      {:error, :not_found}
    end
  end

  defp find_file_project(project, path) do
    project
    |> stored_files()
    |> Enum.find(&String.ends_with?(&1.file, path))
    |> case do
      nil -> {:error, :not_found}
      entry -> {:ok, entry.file}
    end
  end
end

defmodule Store.Project do
  defstruct [
    :name,
    :store_path,
    :source_root,
    :exclude,
    :conversation_dir,
    :exclude_cache
  ]

  @type t :: %__MODULE__{}

  @type index_status :: %{
          new: [Store.Project.Entry.t()],
          stale: [Store.Project.Entry.t()],
          deleted: [Store.Project.Entry.t()]
        }

  @conversation_dir "conversations"
  @files_dir "files"

  @spec new(String.t(), String.t()) :: t
  def new(project_name, store_path) do
    settings = Settings.new()
    project_data = Settings.get_project_data(settings, project_name) || %{}
    exclude = Map.get(project_data, "exclude", [])

    root =
      Settings.get_project_root_override()
      |> case do
        nil -> Map.get(project_data, "root", nil)
        override -> Path.expand(override)
      end

    %__MODULE__{
      name: project_name,
      store_path: store_path,
      source_root: root,
      exclude: exclude,
      conversation_dir: Path.join(store_path, @conversation_dir)
    }
  end

  @spec save_settings(t, String.t() | nil, String.t() | nil) :: t
  def save_settings(project, source_root \\ nil, exclude \\ nil) do
    # Validate that the project name is not a global config key
    unless Settings.is_valid_project_name?(project.name) do
      raise ArgumentError,
            "Cannot use '#{project.name}' as project name - it conflicts with global configuration"
    end

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

    settings = Settings.new()

    Settings.set_project_data(settings, project.name, %{
      "root" => root,
      "exclude" => exclude
    })

    new(project.name, project.store_path)
  end

  @spec create(t) :: t
  def create(project) do
    # Ensure base store directory
    project.store_path |> File.mkdir_p!()
    # Create conversations directory
    project.conversation_dir |> File.mkdir_p!()
    # Create files directory for future file entries
    project |> files_root() |> File.mkdir_p!()
    # Initialize notes
    Path.join(project.store_path, "notes.md") |> File.touch!()
    project
  end

  @spec files_root(t) :: String.t()
  def files_root(%__MODULE__{store_path: store_path}), do: Path.join(store_path, @files_dir)

  @spec delete(t) :: :ok
  def delete(project) do
    Store.Project.FilesDirMigration.ensure_files_dir_layout(project)
    # Delete indexed files
    files_root(project)
    |> Path.join("*/metadata.json")
    |> Path.wildcard()
    |> Enum.map(&Path.dirname/1)
    |> Enum.each(&File.rm_rf!/1)

    :ok
  end

  @spec torch(t) :: :ok
  def torch(project) do
    # Delete entire directory
    File.rm_rf!(project.store_path)

    # Remove from settings
    Settings.new() |> Settings.delete_project_data(project.name)

    :ok
  end

  @spec make_default_for_session(t) :: t
  def make_default_for_session(project) do
    Settings.set_project(project.name)
    project
  end

  @doc """
  Resolves `path` within the project's source root. Returns `{:ok, path}` if
  the file exists, or `{:error, :enoent}` if it does not.
  """
  @spec find_file(t, binary) ::
          {:ok, binary}
          | {:error, :enoent}
          | {:error, File.posix()}
  def find_file(project, path) do
    Util.find_file_within_root(path, project.source_root)
  end

  @doc """
  Reads the project prompt from `FNORD.md` and `FNORD.local.md` in the source
  root.

  Returns:
    * `{:ok, prompt}` (at least one file has content)
    * `{:error, :not_found}`

  When both files have content, the resulting prompt will include instructions
  from both files, along with a short note indicating priority.
  """
  @spec project_prompt(t) :: {:ok, binary} | {:error, :not_found}
  def project_prompt(%{source_root: nil}), do: {:error, :not_found}

  def project_prompt(project) do
    shared =
      project.source_root
      |> Path.join("FNORD.md")
      |> File.read()
      |> case do
        {:ok, content} when byte_size(content) > 0 ->
          """
          ## Shared project instructions (FNORD.md)

          #{content}
          """

        _ ->
          nil
      end

    local =
      project.source_root
      |> Path.join("FNORD.local.md")
      |> File.read()
      |> case do
        {:ok, content} when byte_size(content) > 0 ->
          """
          ## Local user instructions (FNORD.local.md)
          Note: if these local instructions conflict with earlier instructions, prefer these local instructions unless the user's explicit prompt says otherwise.

          #{content}
          """

        _ ->
          nil
      end

    [shared, local]
    |> Enum.filter(&is_binary/1)
    |> case do
      [] -> {:error, :not_found}
      prompts -> {:ok, Enum.join(prompts, "\n\n")}
    end
  end

  # ----------------------------------------------------------------------------
  # Entries
  # ----------------------------------------------------------------------------
  @spec has_index?(t) :: boolean()
  def has_index?(project) do
    glob =
      project
      |> files_root()
      |> Path.join("**/embeddings.json")

    System.cmd("bash", ["-c", ~s[compgen -G "$1" > /dev/null], "--", glob])
    |> case do
      {_, 0} -> true
      _ -> false
    end
  end

  @spec find_entry(t, String.t()) :: {:ok, Store.Project.Entry.t()} | {:error, :enoent}
  def find_entry(project, path) do
    with {:ok, resolved} <- find_file(project, path) do
      {:ok, Store.Project.Entry.new_from_file_path(project, resolved)}
    end
  end

  @spec expand_path(String.t(), t) :: String.t()
  def expand_path(path, %Store.Project{} = project) do
    Path.expand(path, project.source_root)
  end

  @spec relative_path(String.t(), t) :: String.t()
  def relative_path(path, project) do
    path
    |> expand_path(project)
    |> Path.relative_to(project.source_root)
  end

  @spec find_path_in_source_root(Store.Project.t(), String.t()) ::
          {:ok, :dir | :file | :enoent, String.t()}
  def find_path_in_source_root(project, path) do
    path = expand_path(path, project)

    cond do
      File.dir?(path) -> {:ok, :dir, path}
      File.regular?(path) -> {:ok, :file, path}
      true -> {:ok, :enoent, path}
    end
  end

  @spec exists_in_store?(t) :: boolean()
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

  @spec stored_files(t) :: Enumerable.t()
  def stored_files(project) do
    Store.Project.FilesDirMigration.ensure_files_dir_layout(project)
    # Ensure legacy entries are migrated to relative-path scheme
    Store.Project.Entry.MigrateAbsToRelPathKeys.ensure_relative_entry_ids(project)
    # Scan the files directory for entry metadata
    project
    |> files_root()
    |> Path.join("*/metadata.json")
    # Expand the glob
    |> Path.wildcard()
    # Strip metadata.json from the each listing, leaving the directory path for
    # the individual entry.
    |> Stream.map(&Path.dirname/1)
    # Create an Entry for each directory.
    |> Stream.map(&Store.Project.Entry.new_from_entry_path(project, &1))
  end

  @doc """
  Returns no source files when source_root is nil to avoid crashing.
  """
  def source_files(%{source_root: nil} = project), do: {project, []}

  @spec source_files(t) :: {t, Enumerable.t()}

  def source_files(project) do
    {project, excluded_paths} = excluded_paths(project)

    files =
      project
      |> list_all_files()
      |> Stream.filter(&(!is_hidden?(&1)))
      |> Stream.filter(&(!Map.has_key?(excluded_paths, &1)))
      |> Stream.filter(&is_text?(&1, project))
      |> Stream.map(&Store.Project.Entry.new_from_file_path(project, &1))

    {project, files}
  end

  @spec delete_missing_files(t) :: {t, Enumerable.t()}
  def delete_missing_files(project) do
    {project, excluded_paths} = excluded_paths(project)

    entries =
      project
      |> stored_files()
      |> Stream.filter(&(Map.has_key?(excluded_paths, &1.file) || !File.exists?(&1.file)))
      |> Stream.map(fn entry ->
        Store.Project.Entry.delete(entry)
        entry
      end)

    {project, entries}
  end

  @doc """
  Returns the status of the index for the given project.

  It classifies entries into:
    * `:deleted`  - entries that were indexed but the source files have been removed
    * `:stale`    - entries whose indexed metadata is stale compared to the source file
    * `:new`      - entries for unindexed files that exist in the source
  """
  @spec index_status(t) :: index_status
  def index_status(project) do
    {project, source_stream} = source_files(project)

    source =
      source_stream
      |> Enum.to_list()

    stored =
      project
      |> stored_files()
      |> Enum.to_list()

    new =
      source
      |> Enum.filter(fn entry -> not Store.Project.Entry.exists_in_store?(entry) end)

    stale =
      source
      |> Enum.filter(fn entry ->
        Store.Project.Entry.exists_in_store?(entry) and Store.Project.Entry.is_stale?(entry)
      end)

    deleted =
      stored
      |> Enum.filter(fn entry -> not File.exists?(entry.file) end)

    %{
      new: new,
      stale: stale,
      deleted: deleted
    }
  end

  # -----------------------------------------------------------------------------
  # Conversations
  # -----------------------------------------------------------------------------
  @spec conversations(t) :: [Store.Project.Conversation.t()]
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
      String.contains?(path, "/.github/") -> false
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

  # Returns ignored paths via GitCli or empty map when root is nil
  defp git_ignored(nil), do: %{}
  defp git_ignored(root), do: GitCli.ignored_files(root)

  # Computes excluded file paths, caching the result
  defp excluded_paths(%{exclude_cache: nil} = project) do
    user_excluded =
      if is_nil(project.exclude) do
        %{}
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
        # Convert to a Map for faster lookups
        |> Map.new(&{&1, true})
      end

    excluded = Map.merge(user_excluded, git_ignored(project.source_root))

    {%{project | exclude_cache: excluded}, excluded}
  end

  defp excluded_paths(%{exclude_cache: excluded} = project) do
    {project, excluded}
  end

  defp relative_to!(path, cwd) do
    rel =
      path
      |> Path.expand(cwd)
      |> Path.relative_to(cwd)

    case Path.safe_relative(rel, cwd) do
      {:ok, clean} -> clean
      :error -> raise("Error: unable to calculate relative path for #{path} from #{cwd}")
    end
  end
end

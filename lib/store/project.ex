defmodule Store.Project do
  defstruct [
    :name,
    :store_path,
    :source_root,
    :exclude
  ]

  def new(project_name, store_path) do
    settings = Settings.new() |> Settings.get(project_name, %{})
    exclude = Map.get(settings, "exclude", [])
    root = Map.get(settings, "root")

    %__MODULE__{
      name: project_name,
      store_path: store_path,
      source_root: root,
      exclude: exclude
    }
  end

  def save_settings(project, source_root \\ nil, exclude \\ nil) do
    settings = %{
      "root" => project.source_root,
      "exclude" => project.exclude
    }

    settings =
      if is_nil(source_root) do
        settings
      else
        Map.put(settings, "root", source_root)
      end

    settings =
      case exclude do
        nil -> settings
        [] -> settings
        _ -> Map.put(settings, "exclude", exclude)
      end

    Settings.new()
    |> Settings.set(project.name, settings)

    new(project.name, project.store_path)
  end

  def create(project) do
    File.mkdir_p!(project.store_path)
  end

  def delete(project) do
    File.rm_rf!(project.store_path)
  end

  def expand_path(path, project) do
    path
    |> Path.absname(project.source_root)
    |> Path.expand()
  end

  def relative_path(path, project) do
    path
    |> expand_path(project)
    |> Path.relative_to(project.source_root)
  end

  def find_path_in_source_root(project, path) do
    path = expand_path(project, path)

    cond do
      File.dir?(path) -> {:ok, :dir, path}
      File.regular?(path) -> {:ok, :file, path}
      true -> {:ok, :not_found, path}
    end
  end

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

  def stored_files(project) do
    project.store_path
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.map(&Store.Entry.new_from_entry_path(project, &1))
  end

  def source_files(project) do
    excluded = excluded_paths(project)

    DirStream.new(project.source_root, &want_dir?(&1, excluded, project.source_root))
    |> Stream.filter(&want_file?(&1, excluded, project.source_root))
    |> Stream.map(&Store.Entry.new_from_file_path(project, &1))
  end

  def stale_source_files(project) do
    project
    |> source_files()
    |> Stream.filter(&Store.Entry.is_stale?/1)
  end

  def delete_missing_files(project) do
    excluded_files = excluded_paths(project)

    project
    |> stored_files()
    |> Enum.each(fn entry ->
      cond do
        !Store.Entry.source_file_exists?(entry) -> Store.Entry.delete(entry)
        Store.Entry.is_git_ignored?(entry) -> Store.Entry.delete(entry)
        MapSet.member?(excluded_files, entry.file) -> Store.Entry.delete(entry)
        true -> is_text?(entry.file)
      end
    end)
  end

  # -----------------------------------------------------------------------------
  # Private functions
  # -----------------------------------------------------------------------------
  defp want_dir?(path, excluded, source_root) do
    cond do
      # hidden
      is_hidden?(path) -> false
      # explicitly excluded
      MapSet.member?(excluded, path) -> false
      # git-ignored
      Git.is_ignored?(path, source_root) -> false
      # keeper
      true -> true
    end
  end

  defp want_file?(path, excluded, source_root) do
    cond do
      # hidden
      is_hidden?(path) -> false
      # explicitly excluded
      MapSet.member?(excluded, path) -> false
      # git-ignored
      Git.is_ignored?(path, source_root) -> false
      # text only
      true -> is_text?(path)
    end
  end

  defp is_hidden?(path) do
    base = Path.basename(path)

    cond do
      base == ".github" -> false
      String.starts_with?(base, ".") -> true
      true -> false
    end
  end

  defp is_text?(file_path) do
    try do
      file_path
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

  defp excluded_paths(project) do
    if is_nil(project.exclude) do
      MapSet.new()
    else
      project.exclude
      |> Enum.flat_map(fn exclude ->
        exclude
        |> find_path_in_source_root(project)
        |> case do
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
  end
end

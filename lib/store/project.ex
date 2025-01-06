defmodule Store.Project do
  defstruct [
    :name,
    :store_path,
    :source_root,
    :exclude,
    :conversation_dir,
    :notes_dir
  ]

  @conversation_dir "conversations"
  @notes_dir "notes"

  def new(project_name, store_path) do
    settings = Settings.new() |> Settings.get(project_name, %{})
    exclude = Map.get(settings, "exclude", [])
    root = Map.get(settings, "root")

    %__MODULE__{
      name: project_name,
      store_path: store_path,
      source_root: root,
      exclude: exclude,
      conversation_dir: Path.join(store_path, @conversation_dir),
      notes_dir: Path.join(store_path, @notes_dir)
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
    project.store_path |> File.mkdir_p!()
    project.store_path |> Path.join("conversations") |> File.mkdir_p!()
  end

  def delete(project) do
    # Delete indexed files
    project.store_path
    |> Path.join("*/metadata.json")
    |> Path.wildcard()
    |> Enum.map(&Path.dirname/1)
    |> Enum.each(fn path -> File.rm_rf!(path) end)
  end

  def torch(project) do
    # Delete entire directory
    File.rm_rf!(project.store_path)

    # Remove from settings
    Settings.new() |> Settings.delete(project.name)
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
    # Start with the path to the project in the store
    project.store_path
    # Each entry is a dir that contains metadata.json; this step ignores things
    # like the conversations directory.
    |> Path.join("*/metadata.json")
    # Expand the glob
    |> Path.wildcard()
    # Strip metadata.json from the each listing, leaving the directory path for
    # the individual entry.
    |> Enum.map(&Path.dirname/1)
    # Create an Entry for each directory.
    |> Enum.map(&Store.Project.Entry.new_from_entry_path(project, &1))
  end

  def source_files(project) do
    excluded = excluded_paths(project)

    DirStream.new(project.source_root, &want_dir?(&1, excluded, project.source_root))
    |> Stream.filter(&want_file?(&1, excluded, project.source_root))
    |> Stream.map(&Store.Project.Entry.new_from_file_path(project, &1))
  end

  def stale_source_files(project) do
    project
    |> source_files()
    |> Stream.filter(&Store.Project.Entry.is_stale?/1)
  end

  def delete_missing_files(project) do
    excluded_files = excluded_paths(project)

    project
    |> stored_files()
    |> Enum.each(fn entry ->
      cond do
        !Store.Project.Entry.source_file_exists?(entry) -> Store.Project.Entry.delete(entry)
        Store.Project.Entry.is_git_ignored?(entry) -> Store.Project.Entry.delete(entry)
        MapSet.member?(excluded_files, entry.file) -> Store.Project.Entry.delete(entry)
        true -> is_text?(entry.file)
      end
    end)
  end

  # -----------------------------------------------------------------------------
  # Conversations
  # -----------------------------------------------------------------------------
  def conversations(project) do
    conversations =
      project.store_path
      |> Path.join(["conversations/*.json"])
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".json"))
      |> Enum.map(&Store.Project.Conversation.new(&1, project))

    timestamps =
      conversations
      |> Enum.reduce(%{}, fn conversation, acc ->
        timestamp = Store.Project.Conversation.timestamp(conversation)
        Map.put(acc, conversation.id, timestamp)
      end)

    conversations
    |> Enum.sort(fn a, b ->
      timestamps[a.id] > timestamps[b.id]
    end)
  end

  # -----------------------------------------------------------------------------
  # Notes
  # -----------------------------------------------------------------------------
  def notes(project) do
    project.notes_dir
    |> File.ls()
    |> case do
      {:ok, dirs} ->
        dirs
        |> Enum.sort()
        |> Enum.map(&Store.Project.Note.new(project, &1))

      _ ->
        []
    end
  end

  def search_notes(project, query, max_results \\ 10) do
    needle = AI.get_embeddings!(AI.new(), query)

    project
    |> notes()
    |> Enum.reduce([], fn note, acc ->
      with {:ok, embeddings} <- Store.Project.Note.read_embeddings(note) do
        score = AI.Util.cosine_similarity(needle, embeddings)
        [{score, note} | acc]
      else
        _ -> acc
      end
    end)
    |> Enum.sort(fn {a, _}, {b, _} -> a >= b end)
    |> Enum.take(max_results)
  end

  def reset_notes(project) do
    File.rm_rf(project.notes_dir)
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

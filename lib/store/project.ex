defmodule Store.Project do
  defstruct [
    :name,
    :store_path,
    :source_root,
    :exclude,
    :conversation_dir,
    :notes_dir
  ]

  @type t :: %__MODULE__{}

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

  # ----------------------------------------------------------------------------
  # Entries
  # ----------------------------------------------------------------------------
  @spec find_entry(Store.Project.t(), String.t()) ::
          {:ok, Store.Project.Entry.t()}
          | {:error, atom()}
  def find_entry(project, path) do
    with {:ok, resolved} <- find_file(project, path) do
      {:ok, Store.Project.Entry.new_from_file_path(project, resolved)}
    end
  end

  @spec find_file(Store.Project.t(), String.t()) ::
          {:ok, String.t()}
          | {:error, atom()}
  def find_file(project, path) do
    [
      &find_abs_file_root/2,
      &find_abs_file_project/2,
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

  defp find_file_project(project, path) do
    project
    |> stored_files()
    |> Enum.find(&String.ends_with?(&1.file, path))
    |> case do
      nil -> {:error, :not_found}
      entry -> {:ok, entry.file}
    end
  end

  def expand_path(path, project) do
    Path.expand(path, project.source_root)
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
    |> Stream.map(&Path.dirname/1)
    # Create an Entry for each directory.
    |> Stream.map(&Store.Project.Entry.new_from_entry_path(project, &1))
  end

  def source_files(project) do
    excluded = excluded_paths(project)

    DirStream.new(project.source_root, &want_dir?(&1, excluded, project.source_root))
    |> Stream.filter(&want_file?(&1, excluded, project.source_root))
    |> Stream.map(&Store.Project.Entry.new_from_file_path(project, &1))
  end

  def stale_source_files(%Stream{} = files) do
    files
    |> Stream.filter(&Store.Project.Entry.is_stale?/1)
  end

  def stale_source_files(files) when is_list(files) do
    files
    |> Stream.filter(&Store.Project.Entry.is_stale?/1)
  end

  def stale_source_files(project) do
    project
    |> source_files()
    |> stale_source_files()
  end

  def delete_missing_files(project) do
    excluded_files = excluded_paths(project)

    project
    |> stored_files()
    |> Util.async_stream(fn entry ->
      cond do
        !Store.Project.Entry.source_file_exists?(entry) ->
          Store.Project.Entry.delete(entry)
          true

        Store.Project.Entry.is_git_ignored?(entry) ->
          Store.Project.Entry.delete(entry)
          true

        MapSet.member?(excluded_files, entry.file) ->
          Store.Project.Entry.delete(entry)
          true

        true ->
          false
      end
    end)
    |> Stream.filter(fn
      {:ok, true} -> true
      _ -> false
    end)
    |> Enum.count()
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

  def search_notes(project, query, max_results \\ 10, min_similarity \\ 0.4) do
    needle = AI.get_embeddings!(AI.new(), query)
    notes = notes(project)
    workers = Enum.count(notes)

    if workers == 0 do
      []
    else
      notes
      # Retrieve embeddings for each note
      |> Util.async_stream(
        fn note ->
          with {:ok, embeddings} <- Store.Project.Note.read_embeddings(note) do
            {:ok, {note, embeddings}}
          end
        end,
        max_concurrency: workers
      )
      # Calculate the similarity between the query and each note
      |> Util.async_stream(
        fn
          {:ok, {:ok, {note, embeddings}}} ->
            score = AI.Util.cosine_similarity(needle, embeddings)
            {score, note}

          _ ->
            nil
        end,
        max_concurrency: workers
      )
      # Collect the results
      |> Enum.reduce([], fn
        {:ok, {score, note}}, acc when score >= min_similarity ->
          [{score, note} | acc]

        _, acc ->
          acc
      end)
      # Sort by similarity
      |> Enum.sort(fn {a, _}, {b, _} -> a >= b end)
      # Take the top N results
      |> Enum.take(max_results)
    end
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

  defp relative_to!(path, cwd) do
    IO.inspect({path, cwd}, label: "RELATIVE_TO! ARGS")
    IO.inspect(Path.safe_relative(path, cwd), label: "SAFE_RLATIVE")

    with {:ok, path} <- Path.safe_relative(path, cwd) do
      path
    else
      :error -> raise("Error: unable to calculate relative path for #{path} from #{cwd}")
    end
  end
end

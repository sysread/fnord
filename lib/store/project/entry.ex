defmodule Store.Project.Entry do
  defstruct [
    :project,
    :file,
    :rel_path,
    :key,
    :store_path,
    :metadata,
    :summary,
    :outline,
    :embeddings
  ]

  @type t :: %__MODULE__{}

  @id_prefix_reversible "r1-"
  @id_prefix_hash "h1-"
  @max_id_len 240

  @spec new_from_file_path(Store.Project.t(), String.t()) :: t()
  def new_from_file_path(project, file) do
    abs_path = Store.Project.expand_path(file, project)
    rel_path = Store.Project.relative_path(abs_path, project)

    key = id_for_rel_path(rel_path)
    store_path = Path.join(project.store_path, key)
    metadata = Store.Project.Entry.Metadata.new(store_path, abs_path)
    summary = Store.Project.Entry.Summary.new(store_path, abs_path)
    outline = Store.Project.Entry.Outline.new(store_path, abs_path)
    embeddings = Store.Project.Entry.Embeddings.new(store_path, abs_path)

    %__MODULE__{
      project: project,
      file: abs_path,
      rel_path: rel_path,
      key: key,
      store_path: store_path,
      metadata: metadata,
      summary: summary,
      outline: outline,
      embeddings: embeddings
    }
  end

  @spec new_from_entry_path(Store.Project.t(), String.t()) :: t()
  def new_from_entry_path(project, entry_path) do
    with {:ok, content} <- File.read(Path.join(entry_path, "metadata.json")),
         {:ok, metadata} <- Jason.decode(content),
         {:ok, file_field} <- Map.fetch(metadata, "file"),
         true <- is_binary(file_field) do
      
      resolved =
        cond do
          # Legacy absolute path
          String.starts_with?(file_field, "/") ->
            file_field

          # New relative path
          true ->
            Path.expand(file_field, project.source_root)
        end

      new_from_file_path(project, resolved)
    else
      _ ->
        raise """
        Invalid or corrupted metadata in #{entry_path}.
        
        This may indicate a corrupted project index. Try running:
          fnord index --reindex
        """
    end
  end

  @spec exists_in_store?(t()) :: boolean()
  def exists_in_store?(entry) do
    File.dir?(entry.store_path)
  end

  @spec create(t()) :: :ok
  def create(entry), do: File.mkdir_p!(entry.store_path)

  @spec delete(t()) :: [binary()]
  def delete(entry), do: File.rm_rf!(entry.store_path)

  @spec is_incomplete?(t()) :: boolean()
  def is_incomplete?(entry) do
    cond do
      !has_metadata?(entry) -> true
      !has_summary?(entry) -> true
      !has_outline?(entry) -> true
      !has_embeddings?(entry) -> true
      true -> false
    end
  end

  @spec hash_is_current?(t()) :: boolean()
  def hash_is_current?(entry) do
    with {:ok, hash} <- get_last_hash(entry) do
      hash == file_sha256(entry.file)
    else
      _ -> false
    end
  end

  @spec is_stale?(t()) :: boolean()
  def is_stale?(entry) do
    cond do
      # Never indexed
      !exists_in_store?(entry) -> true
      # Files that are missing or have missing indexes must be reindexed
      is_incomplete?(entry) -> true
      # File contents have changed
      !hash_is_current?(entry) -> true
      true -> false
    end
  end

  @spec read_source_file(t()) :: {:ok, String.t()} | {:error, any()}
  def read_source_file(entry), do: File.read(entry.file)

  @spec read(t()) :: {:ok, map()} | {:error, any()}
  def read(entry) do
    with {:ok, metadata} <- read_metadata(entry),
         {:ok, summary} <- read_summary(entry),
         {:ok, outline} <- read_outline(entry),
         {:ok, embeddings} <- read_embeddings(entry) do
      # Ensure the "file" field always contains the absolute path for API compatibility
      info =
        metadata
        |> Map.put("file", entry.file)
        |> Map.put("summary", summary)
        |> Map.put("outline", outline)
        |> Map.put("embeddings", embeddings)

      {:ok, info}
    end
  end

  @spec save(t(), String.t(), String.t(), [float]) :: :ok | {:error, any()}
  def save(entry, summary, outline, embeddings) do
    delete(entry)
    create(entry)

    with :ok <- save_metadata(entry),
         :ok <- save_summary(entry, summary),
         :ok <- save_outline(entry, outline),
         :ok <- save_embeddings(entry, embeddings) do
      :ok
    end
  end

  # -----------------------------------------------------------------------------
  # metadata.json
  # -----------------------------------------------------------------------------
  def metadata_file_path(entry), do: Store.Project.Entry.Metadata.store_path(entry.metadata)
  def has_metadata?(entry), do: Store.Project.Entry.Metadata.exists?(entry.metadata)
  def read_metadata(entry), do: Store.Project.Entry.Metadata.read(entry.metadata)
  def save_metadata(entry) do
    Store.Project.Entry.Metadata.write(entry.metadata, %{rel_path: entry.rel_path})
  end

  # -----------------------------------------------------------------------------
  # summary
  # -----------------------------------------------------------------------------
  def summary_file_path(entry), do: Store.Project.Entry.Summary.store_path(entry.summary)
  def has_summary?(entry), do: Store.Project.Entry.Summary.exists?(entry.summary)
  def read_summary(entry), do: Store.Project.Entry.Summary.read(entry.summary)
  def save_summary(entry, data), do: Store.Project.Entry.Summary.write(entry.summary, data)

  # -----------------------------------------------------------------------------
  # outline
  # -----------------------------------------------------------------------------
  def outline_file_path(entry), do: Store.Project.Entry.Outline.store_path(entry.outline)
  def has_outline?(entry), do: Store.Project.Entry.Outline.exists?(entry.outline)
  def read_outline(entry), do: Store.Project.Entry.Outline.read(entry.outline)
  def save_outline(entry, data), do: Store.Project.Entry.Outline.write(entry.outline, data)

  # -----------------------------------------------------------------------------
  # embeddings
  # -----------------------------------------------------------------------------
  def embeddings_file_paths(entry) do
    Store.Project.Entry.Embeddings.store_path(entry.embeddings)
  end

  def has_embeddings?(entry), do: Store.Project.Entry.Embeddings.exists?(entry.embeddings)
  def read_embeddings(entry), do: Store.Project.Entry.Embeddings.read(entry.embeddings)

  def save_embeddings(entry, embeddings) do
    Store.Project.Entry.Embeddings.write(entry.embeddings, embeddings)
  end

  # -----------------------------------------------------------------------------
  # Private functions
  # -----------------------------------------------------------------------------
  defp get_last_hash(entry) do
    with {:ok, metadata} <- read_metadata(entry) do
      Map.fetch(metadata, "hash")
    end
  end


  defp file_sha256(file_path) do
    case File.read(file_path) do
      {:ok, content} -> sha256(content)
      {:error, reason} -> {:error, reason}
    end
  end

  defp sha256(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  end

  @spec id_for_rel_path(String.t()) :: String.t()
  def id_for_rel_path(rel_path) do
    # Try reversible ID first
    reversible_id = @id_prefix_reversible <> Base.url_encode64(rel_path, padding: false)
    
    if byte_size(reversible_id) <= @max_id_len do
      reversible_id
    else
      # Fall back to hash for long paths
      @id_prefix_hash <> sha256(rel_path)
    end
  end


  @spec rel_path_from_id(String.t()) :: {:ok, String.t()} | {:error, :not_reversible}
  def rel_path_from_id(id) do
    cond do
      String.starts_with?(id, @id_prefix_reversible) ->
        encoded = String.slice(id, String.length(@id_prefix_reversible)..-1//1)
        case Base.url_decode64(encoded, padding: false) do
          {:ok, rel_path} -> {:ok, rel_path}
          :error -> {:error, :not_reversible}
        end
      
      String.starts_with?(id, @id_prefix_hash) ->
        {:error, :not_reversible}
      
      true ->
        # Legacy absolute path hash
        {:error, :not_reversible}
    end
  end

end

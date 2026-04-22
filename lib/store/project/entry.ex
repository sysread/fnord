defmodule Store.Project.Entry do
  defstruct [
    :project,
    :file,
    :rel_path,
    :key,
    :store_path,
    :metadata,
    :summary,
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
    store_base = Store.Project.files_root(project)
    store_path = Path.join(store_base, key)
    metadata = Store.Project.Entry.Metadata.new(store_path, abs_path)
    summary = Store.Project.Entry.Summary.new(store_path, abs_path)
    embeddings = Store.Project.Entry.Embeddings.new(store_path, abs_path)

    %__MODULE__{
      project: project,
      file: abs_path,
      rel_path: rel_path,
      key: key,
      store_path: store_path,
      metadata: metadata,
      summary: summary,
      embeddings: embeddings
    }
  end

  @spec new_from_entry_path(Store.Project.t(), String.t()) :: t()
  def new_from_entry_path(project, entry_path) do
    with {:ok, content} <- File.read(Path.join(entry_path, "metadata.json")),
         {:ok, metadata} <- SafeJson.decode(content),
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
      !has_embeddings?(entry) -> true
      true -> false
    end
  end

  @spec is_stale?(t()) :: boolean()
  def is_stale?(entry) do
    cond do
      !exists_in_store?(entry) ->
        true

      !has_summary?(entry) ->
        true

      !has_embeddings?(entry) ->
        true

      true ->
        # Read metadata.json once and thread it through the remaining
        # checks. Each per-file scan pays a single disk+decode cost
        # instead of one read for the hash and another (indirectly, via
        # the embeddings file) for the dim.
        case read_metadata(entry) do
          {:ok, metadata} ->
            not hash_is_current?(entry, metadata) or
              not embedding_dim_is_current?(entry, metadata)

          _ ->
            true
        end
    end
  end

  # An entry whose stored embedding vector was produced by a different
  # model (e.g. pre-migration OpenAI 3072-dim data that the cross-format
  # hash upgrade marked as "fresh") is still stale from the embedding
  # layer's perspective: cosine_similarity would crash against the new
  # query vectors. The dim is recorded in metadata at save time so this
  # check is O(1) disk; older stores that predate that field fall back
  # to reading the embeddings file once and backfilling so the next
  # scan takes the fast path.
  @spec embedding_dim_is_current?(t(), map()) :: boolean()
  defp embedding_dim_is_current?(entry, metadata) do
    current = AI.Embeddings.dimensions()

    case Map.get(metadata, "embedding_dim") do
      dim when is_integer(dim) ->
        dim == current

      _ ->
        case Store.Project.Entry.Embeddings.read(entry.embeddings) do
          {:ok, list} when is_list(list) ->
            actual = length(list)

            if actual == current do
              backfill_embedding_dim(entry, metadata, actual)
              true
            else
              false
            end

          _ ->
            false
        end
    end
  end

  # Re-stamps metadata with the discovered dim so subsequent scans
  # answer embedding_dim_is_current? from metadata alone. No-op when
  # metadata is missing the hash (we don't invent one) - the next
  # successful save/3 will record both fields together.
  defp backfill_embedding_dim(entry, metadata, dim) do
    case Map.get(metadata, "hash") do
      hash when is_binary(hash) -> save_metadata(entry, hash, embedding_dim: dim)
      _ -> :ok
    end
  end

  @spec read(t()) :: {:ok, map()} | {:error, any()}
  def read(entry) do
    with {:ok, metadata} <- read_metadata(entry),
         {:ok, summary} <- read_summary(entry),
         {:ok, embeddings} <- read_embeddings(entry) do
      info =
        metadata
        |> Map.put("file", entry.file)
        |> Map.put("summary", summary)
        |> Map.put("embeddings", embeddings)

      {:ok, info}
    end
  end

  @spec save(t(), String.t(), [float]) :: :ok | {:error, any()}
  def save(entry, summary, embeddings) do
    delete(entry)
    create(entry)

    with {:ok, hash} <- Store.Project.Source.hash(entry.project, entry.rel_path),
         :ok <- save_metadata(entry, hash, embedding_dim: embedding_length(embeddings)),
         :ok <- save_summary(entry, summary),
         :ok <- save_embeddings(entry, embeddings) do
      :ok
    end
  end

  # Width of a single embedding vector. Indexer.get_embeddings returns a
  # flat list of floats today, but accept the legacy nested shape too so
  # this helper stays robust if a caller ever hands us the pre-collapse
  # per-chunk layout.
  defp embedding_length([]), do: 0
  defp embedding_length([first | _]) when is_list(first), do: length(first)
  defp embedding_length(list) when is_list(list), do: length(list)
  defp embedding_length(_), do: 0

  @spec hash_is_current?(t()) :: boolean()
  def hash_is_current?(entry) do
    case read_metadata(entry) do
      {:ok, metadata} -> hash_is_current?(entry, metadata)
      _ -> false
    end
  end

  @spec hash_is_current?(t(), map()) :: boolean()
  def hash_is_current?(entry, metadata) do
    with {:ok, stored} <- Map.fetch(metadata, "hash"),
         {:ok, current} <- Store.Project.Source.hash(entry.project, entry.rel_path) do
      cond do
        stored == current ->
          true

        # Cross-format match: stored hash was produced by an older fnord
        # (sha256 of working-tree content) while the current source mode
        # produces a different hash (git blob SHA). If the actual content
        # is unchanged, we re-stamp the metadata to the current format in
        # place rather than blowing a full LLM summarize + embed pass on
        # a file that hasn't changed at all.
        content_unchanged?(entry, stored) ->
          restamp_metadata_hash(entry, metadata, current)
          true

        true ->
          false
      end
    else
      _ -> false
    end
  end

  # The cross-format hash upgrade rewrites metadata with the
  # current-format hash. Preserves embedding_dim if the older metadata
  # had it - otherwise the next scan would have to reopen the
  # embeddings file to rediscover the dim we just threw away.
  defp restamp_metadata_hash(entry, metadata, current) do
    opts =
      case Map.get(metadata, "embedding_dim") do
        dim when is_integer(dim) -> [embedding_dim: dim]
        _ -> []
      end

    save_metadata(entry, current, opts)
  end

  # Stored is sha256 (64 hex) only if it came from the pre-Source/fs-mode
  # era. Compare the current source content's sha256 to the stored value;
  # equal means "same content, different hash format".
  defp content_unchanged?(entry, stored) when is_binary(stored) do
    case byte_size(stored) do
      64 ->
        case Store.Project.Source.read(entry.project, entry.rel_path) do
          {:ok, content} -> sha256(content) == stored
          _ -> false
        end

      _ ->
        false
    end
  end

  defp content_unchanged?(_entry, _stored), do: false

  @spec read_source_file(t()) :: {:ok, binary} | {:error, any()}
  def read_source_file(entry) do
    Store.Project.Source.read(entry.project, entry.rel_path)
  end

  # -----------------------------------------------------------------------------
  # metadata.json
  # -----------------------------------------------------------------------------
  def metadata_file_path(entry), do: Store.Project.Entry.Metadata.store_path(entry.metadata)
  def has_metadata?(entry), do: Store.Project.Entry.Metadata.exists?(entry.metadata)
  def read_metadata(entry), do: Store.Project.Entry.Metadata.read(entry.metadata)

  @spec save_metadata(t(), binary, keyword) :: :ok | {:error, any()}
  def save_metadata(entry, hash, opts \\ []) when is_binary(hash) do
    base = %{rel_path: entry.rel_path, hash: hash}

    attrs =
      case Keyword.get(opts, :embedding_dim) do
        dim when is_integer(dim) -> Map.put(base, :embedding_dim, dim)
        _ -> base
      end

    Store.Project.Entry.Metadata.write(entry.metadata, attrs)
  end

  # Back-compat for callers that still hash the working tree directly.
  # Used only by tests / tooling that reach into the entry directly
  # rather than going through the Source-aware `save/3` pipeline.
  def save_metadata(entry) do
    case Store.Project.Source.hash(entry.project, entry.rel_path) do
      {:ok, hash} -> save_metadata(entry, hash)
      {:error, reason} -> {:error, reason}
    end
  end

  # -----------------------------------------------------------------------------
  # summary
  # -----------------------------------------------------------------------------
  def summary_file_path(entry), do: Store.Project.Entry.Summary.store_path(entry.summary)
  def has_summary?(entry), do: Store.Project.Entry.Summary.exists?(entry.summary)
  def read_summary(entry), do: Store.Project.Entry.Summary.read(entry.summary)
  def save_summary(entry, data), do: Store.Project.Entry.Summary.write(entry.summary, data)

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

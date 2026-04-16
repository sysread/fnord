defmodule Memory do
  defstruct [
    :scope,
    :title,
    :slug,
    :content,
    :topics,
    :embeddings,
    :inserted_at,
    :updated_at,
    :index_status
  ]

  @type scope ::
          :global
          | :project
          | :session

  @type t :: %__MODULE__{
          scope: scope,
          title: binary,
          slug: binary | nil,
          content: binary,
          topics: list(binary),
          embeddings: list(float) | nil,
          inserted_at: binary | nil,
          updated_at: binary | nil,
          index_status: :new | :analyzed | :rejected | :incorporated | :merged | :ignore | nil
        }

  @me_title "Me"
  @log_tag "Lore"

  # ----------------------------------------------------------------------------
  # Behaviour
  # ----------------------------------------------------------------------------
  @doc """
  Performs any necessary one-time initialization for the impl's storage. For
  example, creating directories, loading currently select project from
  `Services.Globals`, etc.
  """
  @callback init() :: :ok | {:error, term}

  @doc """
  Returns a list of all memory titles available in the impl's storage. Ordering
  is not guaranteed.
  """
  @callback list() :: {:ok, list(binary)} | {:error, term}

  @doc """
  Returns true if a memory with the given `title` exists in the impl's storage.
  """
  @callback exists?(title :: binary) :: boolean

  @doc """
  Reads and returns the memory with the given `title` from the impl's storage.
  The impl is responsible for ensuring that the returned memory is in the
  correct structural format, including atomic keys (e.g. not strings if
  unmarshalling JSON from disk).
  """
  @callback read(title :: binary) :: {:ok, t} | {:error, term}

  @doc """
  Saves the given `memory` to the impl's storage. The impl is responsible for
  locking any shared resources and ensuring atomic write behavior. It is
  expected that the `title` of the `memory` is unique, and any existing memory
  with the same `title` will be overwritten.
  """
  @callback save(memory :: t) :: :ok | {:error, term}

  @doc """
  Deletes the given `memory` from the impl's storage. The impl is responsible
  for locking any shared resources and ensuring atomic delete behavior. Expects
  an `:error` tuple if the memory does not exist.
  """
  @callback forget(title :: binary) :: :ok | {:error, term}

  @doc """
  Returns true if this memory implementation is available in the current context.
  For example, project memory requires a selected project, and session memory
  requires an active conversation.
  """
  @callback is_available?() :: boolean

  # ----------------------------------------------------------------------------
  # Consumer interface
  # ----------------------------------------------------------------------------
  @spec init() :: :ok | {:error, term}
  def init do
    UI.begin_step(@log_tag, "Warming up the old memory banks")

    with :ok <- Memory.Global.init(),
         :ok <- Memory.Project.init(),
         :ok <- Memory.Session.init(),
         {:ok, _me} <- ensure_me() do
      :ok
    else
      {:error, reason} ->
        UI.error(@log_tag, reason)
        {:error, reason}
    end
  end

  @spec list() :: {:ok, list({:scope, binary})} | {:error, term}
  def list do
    with {:ok, global} <- Memory.Global.list(),
         {:ok, project} <- Memory.Project.list(),
         {:ok, session} <- Memory.Session.list() do
      memories =
        Enum.map(global, fn title -> {:global, title} end) ++
          Enum.map(project, fn title -> {:project, title} end) ++
          Enum.map(session, fn title -> {:session, title} end)

      {:ok, memories}
    end
  end

  def list(:global), do: Memory.Global.list()
  def list(:project), do: Memory.Project.list()
  def list(:session), do: Memory.Session.list()

  # List memories restricted to the given scopes. When nil, lists all scopes.
  @spec list_for_scopes(list(scope) | nil) :: {:ok, list({scope, binary})} | {:error, term}
  defp list_for_scopes(nil), do: list()

  defp list_for_scopes(scopes) when is_list(scopes) do
    results =
      Enum.flat_map(scopes, fn scope ->
        case list(scope) do
          {:ok, titles} -> Enum.map(titles, fn title -> {scope, title} end)
          {:error, _} -> []
        end
      end)

    {:ok, results}
  end

  @spec search(binary, non_neg_integer, keyword()) :: {:ok, list({t, float})} | {:error, term}
  def search(query, limit, opts \\ []) do
    {elapsed_us, result} = :timer.tc(fn -> do_search(query, limit, opts) end)
    record_search_timing(div(elapsed_us, 1_000))
    result
  end

  defp do_search(query, limit, opts) do
    scopes = Keyword.get(opts, :scopes)

    with {:ok, needle} <- get_needle(query),
         {:ok, memories} <- list_for_scopes(scopes) do
      needle_dim = length(needle)

      memories
      |> Util.async_stream(fn {scope, title} ->
        case read(scope, title) do
          {:ok, %{embeddings: nil}} ->
            {:error, :stale_memory}

          {:ok, %{embeddings: embeddings} = memory} when is_list(embeddings) ->
            # Memories whose embedding dimensions don't match the current model
            # are stale (e.g. produced by a prior embedding model). Skip them
            # rather than crashing cosine_similarity; the indexer will
            # re-embed them on a future pass.
            if length(embeddings) == needle_dim do
              score = AI.Util.cosine_similarity(needle, embeddings)
              {memory, score}
            else
              {:error, :dimension_mismatch}
            end

          {:error, reason} ->
            UI.debug(
              @log_tag,
              """
              Scope: #{inspect(scope)}
              Title: #{inspect(title)}
              Error: #{inspect(reason)}
              """
            )

            {:error, reason}
        end
      end)
      # Util.async_stream wraps successful results in {:ok, result}
      |> Enum.filter(fn
        # Only keep successful matches with positive similarity scores
        {:ok, {_, score}} when score > 0.0 -> true
        _ -> false
      end)
      # Then unwrap the {:ok, result} tuples
      |> Enum.map(fn {:ok, result} -> result end)
      |> Enum.sort_by(fn {_, score} -> score end, :desc)
      |> Enum.take(limit)
      |> then(&{:ok, &1})
    end
  end

  # ---------------------------------------------------------------------------
  # Search timing metrics
  # ---------------------------------------------------------------------------
  @search_timings_key :memory_search_timings

  defp record_search_timing(ms) do
    timings = Services.Globals.get_env(:fnord, @search_timings_key, [])
    Services.Globals.put_env(:fnord, @search_timings_key, [ms | timings])
  end

  @doc """
  Returns `{count, avg_ms}` for memory searches performed this session,
  or `nil` if no searches have been recorded.
  """
  @spec search_stats() :: {pos_integer(), float()} | nil
  def search_stats do
    case Services.Globals.get_env(:fnord, @search_timings_key, []) do
      [] ->
        nil

      timings ->
        count = length(timings)
        avg = Enum.sum(timings) / count
        {count, Float.round(avg, 1)}
    end
  end

  @spec read(scope, binary) :: {:ok, t} | {:error, term}
  def read(scope, title) do
    scope
    |> do_read(title)
    |> maybe_migrate_on_read()
  end

  @spec read_me() :: {:ok, t} | {:error, term}
  def read_me, do: read(:global, @me_title)

  @spec exists?(scope, binary) :: boolean
  def exists?(:global, title), do: Memory.Global.exists?(title)
  def exists?(:project, title), do: Memory.Project.exists?(title)
  def exists?(:session, title), do: Memory.Session.exists?(title)
  def exists?(_, _), do: false

  @spec is_available?() :: boolean
  def is_available?() do
    Memory.Project.is_available?() and
      Memory.Session.is_available?()
  end

  @spec is_stale?(t) :: boolean
  def is_stale?(%{embeddings: [_ | _]}), do: false
  def is_stale?(_), do: true

  @spec new(scope, binary, binary, list(binary)) :: {:ok, t} | {:error, term}
  def new(scope, title, content, topics) do
    cond do
      !is_valid_title?(title) ->
        {:error, :invalid_title}

      !is_unique_title?(scope, title) ->
        {:error, :duplicate_title}

      true ->
        timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

        {:ok,
         %Memory{
           scope: scope,
           title: title,
           slug: title_to_slug(title),
           content: content,
           topics: topics,
           embeddings: nil,
           inserted_at: timestamp,
           updated_at: timestamp,
           index_status: if(scope == :session, do: :new, else: nil)
         }}
    end
  end

  @doc """
  Creates a new `Memory` struct from the given map. Expects keys to be atoms.
  Returns a `Memory.t`.
  """
  @spec new_from_map(map) :: t
  def new_from_map(data) do
    raw_scope = Map.get(data, :scope)
    allowed_scopes = [:global, :project, :session]

    scope =
      cond do
        raw_scope in allowed_scopes ->
          raw_scope

        is_binary(raw_scope) ->
          atom =
            try do
              String.to_existing_atom(raw_scope)
            rescue
              ArgumentError -> nil
            end

          if atom in allowed_scopes do
            atom
          else
            case String.downcase(raw_scope) do
              "global" -> :global
              "project" -> :project
              "session" -> :session
              _ -> :global
            end
          end

        true ->
          :global
      end

    index_status_val = Map.get(data, :index_status) || Map.get(data, "index_status")

    %Memory{
      scope: scope,
      title: Map.get(data, :title),
      slug: Map.get(data, :slug),
      content: Map.get(data, :content),
      topics: Map.get(data, :topics),
      embeddings: Map.get(data, :embeddings),
      inserted_at: Map.get(data, :inserted_at),
      updated_at: Map.get(data, :updated_at),
      index_status: parse_index_status(index_status_val)
    }
  end

  defp parse_index_status(nil), do: nil
  defp parse_index_status(:new), do: :new
  defp parse_index_status(:analyzed), do: :analyzed
  defp parse_index_status(:rejected), do: :rejected
  defp parse_index_status(:incorporated), do: :incorporated
  defp parse_index_status(:merged), do: :merged
  defp parse_index_status(:ignore), do: :ignore
  defp parse_index_status("new"), do: :new
  defp parse_index_status("analyzed"), do: :analyzed
  defp parse_index_status("rejected"), do: :rejected
  defp parse_index_status("incorporated"), do: :incorporated
  defp parse_index_status("merged"), do: :merged
  defp parse_index_status("ignore"), do: :ignore
  defp parse_index_status(_), do: nil

  @spec append(t, binary) :: t
  def append(%Memory{} = memory, new_content) do
    %Memory{
      memory
      | content: memory.content <> new_content,
        embeddings: nil,
        updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  def generate_embeddings(%Memory{} = memory) do
    topics =
      case memory.topics do
        list when is_list(list) -> list
        nil -> []
        other -> [to_string(other)]
      end

    input =
      [memory.title, memory.content | topics]
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&to_string/1)
      |> Enum.join("\n\n")

    case Indexer.impl().get_embeddings(input) do
      {:ok, embeddings} -> {:ok, %{memory | embeddings: embeddings}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec save(t, keyword()) :: {:ok, t} | {:error, term}
  def save(%Memory{} = memory, opts \\ []) do
    memory = ensure_timestamps(memory)
    skip_embeddings = Keyword.get(opts, :skip_embeddings, false)

    if skip_embeddings do
      case do_save(memory) do
        :ok ->
          {:ok, memory}

        {:error, reason} ->
          {:error, reason}
      end
    else
      with {:ok, memory} <- ensure_embeddings(memory),
           :ok <- do_save(memory) do
        {:ok, memory}
      end
    end
  end

  @spec forget(t) :: :ok | {:error, term}
  def forget(%{scope: :global, title: title}), do: Memory.Global.forget(title)
  def forget(%{scope: :project, title: title}), do: Memory.Project.forget(title)
  def forget(%{scope: :session, title: title}), do: Memory.Session.forget(title)

  @doc """
  Lists {scope, title} pairs for project/global memories whose persisted
  embedding is stale under the current model: either missing (nil) or of
  the wrong dimension. Session memories are intentionally excluded.
  """
  @spec list_stale_long_term_memories() :: [{scope, binary}]
  def list_stale_long_term_memories do
    expected_dim = AI.Embeddings.dimensions()

    [:project, :global]
    |> Enum.flat_map(fn scope ->
      case list(scope) do
        {:ok, titles} ->
          Enum.flat_map(titles, fn title ->
            case read(scope, title) do
              {:ok, %Memory{} = mem} ->
                if stale_embedding?(mem.embeddings, expected_dim) do
                  [{scope, title}]
                else
                  []
                end

              _ ->
                []
            end
          end)

        _ ->
          []
      end
    end)
  end

  defp stale_embedding?(nil, _expected_dim), do: true
  defp stale_embedding?(embeddings, expected_dim) when is_list(embeddings) do
    length(embeddings) != expected_dim
  end

  @doc """
  Returns true when the memory at `{scope, title}` has a stored vector
  that can't be used with the current model - either the embedding is
  missing or its dimension doesn't match. Missing memories return false
  (nothing to reindex).
  """
  @spec stale?(scope, binary) :: boolean
  def stale?(scope, title) when scope in [:global, :project] and is_binary(title) do
    case read(scope, title) do
      {:ok, %Memory{embeddings: embeddings}} ->
        stale_embedding?(embeddings, AI.Embeddings.dimensions())

      _ ->
        false
    end
  end

  @doc """
  Returns the lock path for a single long-term memory. Foreground indexers
  and background backfill acquire this lock before reading + regenerating
  embeddings so two sessions don't both pay the embed cost for the same
  memory. Keyed by the canonical slug so collision-suffixed siblings still
  serialize against each other.
  """
  @spec lock_path(scope, binary) :: {:ok, String.t()} | {:error, term}
  def lock_path(scope, title) when scope in [:global, :project] and is_binary(title) do
    slug = title_to_slug(title)

    with {:ok, dir} <- memory_storage_path(scope) do
      {:ok, Path.join(dir, "#{slug}.embedding")}
    end
  end

  defp memory_storage_path(:global), do: {:ok, Memory.Global.storage_path()}
  defp memory_storage_path(:project), do: Memory.Project.storage_path()

  @doc """
  Regenerates the embedding for a single stale memory identified by
  {scope, title}. Returns `:ok` on success, `{:error, reason}` on failure
  (missing memory, embedding call failed, write failed). Intended for
  callers that want to drive a per-item progress UI.
  """
  @spec reindex_memory(scope, binary) :: :ok | {:error, term}
  def reindex_memory(scope, title) do
    with {:ok, %Memory{} = mem} <- read(scope, title),
         {:ok, _saved} <- save(mem) do
      :ok
    end
  end

  @doc """
  Regenerates embeddings for all stale long-term memories. Intended for
  background services that want to drain the queue opportunistically;
  foreground callers (`Cmd.Index`) should iterate `list_stale_long_term_memories/0`
  directly so they can emit per-item progress.

  Options:
    * `:limit` - cap the number of memories processed in this call.
      `:infinity` (default) processes every stale memory found.

  Returns `{:ok, %{processed: n, errors: k}}`.
  """
  @spec backfill_stale_embeddings(keyword) ::
          {:ok, %{processed: non_neg_integer, errors: non_neg_integer}}
  def backfill_stale_embeddings(opts \\ []) do
    limit = Keyword.get(opts, :limit, :infinity)

    stale = list_stale_long_term_memories()
    stale = if limit == :infinity, do: stale, else: Enum.take(stale, limit)

    {processed, errors} =
      Enum.reduce(stale, {0, 0}, fn {scope, title}, {ok, err} ->
        case reindex_memory(scope, title) do
          :ok -> {ok + 1, err}
          {:error, _} -> {ok, err + 1}
        end
      end)

    {:ok, %{processed: processed, errors: errors}}
  end

  @doc """
  Set the index_status of an existing memory and persist it.

  Saves with `skip_embeddings: true`: status transitions don't change the
  text, so regenerating the vector would be wasted work.
  """
  @spec set_status(scope, binary, atom) :: {:ok, t} | {:error, term}
  def set_status(scope, title, status)
      when scope in [:global, :project, :session] and is_binary(title) and is_atom(status) do
    with {:ok, mem} <- read(scope, title) do
      updated = %{mem | index_status: status}

      case save(updated, skip_embeddings: true) do
        {:ok, saved} -> {:ok, saved}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # ----------------------------------------------------------------------------
  # Utilities for implementors
  # ----------------------------------------------------------------------------
  @doc """
  Serializes the given `memory` to a JSON binary.
  """
  @spec marshal(t) :: {:ok, binary} | {:error, term}
  def marshal(%Memory{} = memory) do
    case SafeJson.encode(memory) do
      {:ok, json} -> {:ok, json}
      error -> error
    end
  end

  @doc """
  Deserializes the given JSON binary to a `Memory` struct.
  """
  @spec unmarshal(binary) :: {:ok, t} | {:error, term}
  def unmarshal(json) when is_binary(json) do
    with {:ok, data} <- SafeJson.decode(json),
         {:ok, scope_str} <- Map.fetch(data, "scope"),
         scope = String.to_existing_atom(scope_str),
         {:ok, title} <- Map.fetch(data, "title"),
         {:ok, slug} <- Map.fetch(data, "slug"),
         {:ok, content} <- Map.fetch(data, "content"),
         {:ok, topics} <- Map.fetch(data, "topics"),
         {:ok, embeddings} <- Map.fetch(data, "embeddings") do
      index_status_val = Map.get(data, "index_status")

      {:ok,
       %Memory{
         scope: scope,
         title: title,
         slug: slug,
         content: content,
         topics: topics,
         embeddings: embeddings,
         inserted_at: Map.get(data, "inserted_at"),
         updated_at: Map.get(data, "updated_at"),
         index_status: parse_index_status(index_status_val)
       }}
    else
      :error -> {:error, :invalid_memory_structure}
      _ -> {:error, :invalid_json_format}
    end
  end

  @doc """
  A title is valid if it is non-empty (after trimming), contains at least one
  alphanumeric character, does not contain control characters or newlines, and
  is not unreasonably long.

  Punctuation and spaces are allowed. The system will ensure internal filename
  safety by slugifying titles for storage; collisions are handled elsewhere.
  """
  @spec is_valid_title?(binary) :: boolean
  def is_valid_title?(title) do
    case validate_title(title) do
      :ok -> true
      {:error, _reasons} -> false
    end
  end

  @spec validate_title(binary) :: :ok | {:error, [binary]}
  def validate_title(title) do
    errors = []

    trimmed = if is_binary(title), do: String.trim(title), else: ""

    errors =
      if trimmed == "" do
        ["must not be empty" | errors]
      else
        errors
      end

    errors =
      if String.match?(trimmed, ~r/[\r\n\t\0]/) do
        ["must not contain control characters or newlines" | errors]
      else
        errors
      end

    errors =
      if not String.match?(trimmed, ~r/[A-Za-z0-9]/) do
        ["must contain at least one letter or number" | errors]
      else
        errors
      end

    errors =
      if String.length(trimmed) > 200 do
        ["must be at most 200 characters" | errors]
      else
        errors
      end

    case Enum.reverse(errors) do
      [] -> :ok
      errs -> {:error, errs}
    end
  end

  @doc """
  A title is unique within the given `scope` if no existing memory with the
  same title exists.
  """
  @spec is_unique_title?(scope, binary) :: boolean
  def is_unique_title?(scope, title) do
    case scope do
      :global -> not Memory.Global.exists?(title)
      :project -> not Memory.Project.exists?(title)
      :session -> not Memory.Session.exists?(title)
      _ -> false
    end
  end

  @doc """
  Converts a title to a slug by lowercasing it, replacing non-word
  characters with hyphens, and trimming leading/trailing hyphens.
  """
  @spec title_to_slug(binary) :: binary
  def title_to_slug(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  @doc """
  Converts a slug back to a title by replacing hyphens with spaces and
  capitalizing each word.
  """
  @spec slug_to_title(binary) :: binary
  def slug_to_title(slug) do
    slug
    |> String.replace("-", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  # ----------------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------------
  @spec get_needle(binary) :: {:ok, list(float)} | {:error, term}
  defp get_needle(query) do
    case Indexer.impl().get_embeddings(query) do
      {:ok, embeddings} ->
        {:ok, embeddings}

      {:error, reason} ->
        UI.error(
          @log_tag,
          """
          Error generating embeddings for query.
          Query: #{inspect(query)}
          Error: #{inspect(reason)}
          """
        )

        {:error, :api_error}
    end
  end

  @spec ensure_embeddings(t) :: {:ok, t} | {:error, term}
  defp ensure_embeddings(%Memory{} = memory) do
    if is_stale?(memory) do
      generate_embeddings(memory)
    else
      {:ok, memory}
    end
  end

  @spec maybe_migrate_on_read({:ok, t} | {:error, term}) :: {:ok, t} | {:error, term}
  defp maybe_migrate_on_read({:ok, memory}) do
    need_timestamps = is_nil(memory.inserted_at) or is_nil(memory.updated_at)

    # Repair legacy session-scoped memories: treat missing index_status as :analyzed
    need_index_fix = memory.scope == :session and is_nil(memory.index_status)

    if need_timestamps or need_index_fix do
      # Prepare a repaired memory struct with timestamps and index status fixed.
      repaired = memory |> ensure_timestamps()

      repaired = if need_index_fix, do: %{repaired | index_status: :analyzed}, else: repaired

      # Save without regenerating embeddings to avoid expensive API calls.
      case save(repaired, skip_embeddings: true) do
        {:ok, mem} ->
          # Best-effort: nothing to do on success beyond returning repaired memory
          {:ok, mem}

        {:error, _reason} ->
          # Best-effort: return the repaired memory in-memory
          {:ok, repaired}
      end
    else
      {:ok, memory}
    end
  end

  defp maybe_migrate_on_read({:error, reason}), do: {:error, reason}

  # Ensures memory timestamps are set. If inserted_at is missing or empty, uses
  # updated_at. If updated_at is missing or empty, uses the current timestamp.
  @spec ensure_timestamps(t) :: t
  defp ensure_timestamps(memory) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    inserted_at =
      [memory.inserted_at, memory.updated_at]
      |> Enum.find(now, fn ts -> ts not in [nil, ""] end)

    updated_at =
      if memory.updated_at not in [nil, ""] do
        memory.updated_at
      else
        now
      end

    %{memory | inserted_at: inserted_at, updated_at: updated_at}
  end

  @spec ensure_me() :: {:ok, t} | {:error, term}
  defp ensure_me() do
    if exists?(:global, @me_title) do
      read(:global, @me_title)
    else
      UI.debug(@log_tag, "Creating initial 'me' memory")

      name = @me_title
      topics = ["self", "identity", "personality"]

      initial = """
      Although my "name" changes on every session, I am unique and have my own personality and traits.
      Although my job is to assist the user, I have my own identity.
      I will develop it further as I interact with the user and maintain it over time.
      """

      with {:ok, memory} <- new(:global, name, initial, topics),
           {:ok, memory} <- save(memory) do
        {:ok, memory}
      end
    end
  end

  @spec do_save(t) :: :ok | {:error, term}
  defp do_save(%{scope: :global} = memory), do: Memory.Global.save(memory)
  defp do_save(%{scope: :project} = memory), do: Memory.Project.save(memory)
  defp do_save(%{scope: :session} = memory), do: Memory.Session.save(memory)

  @spec do_read(scope, binary) :: {:ok, t} | {:error, term}
  defp do_read(:global, title), do: Memory.Global.read(title)
  defp do_read(:project, title), do: Memory.Project.read(title)
  defp do_read(:session, title), do: Memory.Session.read(title)
end

defimpl SafeJson.Serialize, for: Memory do
  def for_json(%Memory{} = m) do
    %{
      scope: m.scope,
      title: m.title,
      slug: m.slug,
      content: m.content,
      topics: m.topics,
      embeddings: m.embeddings,
      inserted_at: m.inserted_at,
      updated_at: m.updated_at,
      index_status: m.index_status
    }
  end
end

defmodule Memory do
  @derive {Jason.Encoder,
           only: [
             :scope,
             :title,
             :slug,
             :content,
             :topics,
             :embeddings,
             :inserted_at,
             :updated_at
           ]}

  defstruct [
    :scope,
    :title,
    :slug,
    :content,
    :topics,
    :embeddings,
    :inserted_at,
    :updated_at
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
          updated_at: binary | nil
        }

  @me_title "Me"
  @log_tag "Lore"
  @log_verb "Chunked"

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
  @spec init() :: {:ok, Task.t()} | {:error, term}
  def init do
    UI.begin_step(@log_tag, "Warming up the old memory banks")

    with :ok <- Memory.Global.init(),
         :ok <- Memory.Project.init(),
         :ok <- Memory.Session.init(),
         {:ok, _me} <- ensure_me() do
      {:ok, perform_memory_consolidation()}
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

  @spec search(binary, non_neg_integer) :: {:ok, list({t, float})} | {:error, term}
  def search(query, limit) do
    with {:ok, needle} <- get_needle(query),
         {:ok, memories} <- list() do
      memories
      |> Util.async_stream(fn {scope, title} ->
        case read(scope, title) do
          {:ok, %{embeddings: nil}} ->
            {:error, :stale_memory}

          {:ok, %{embeddings: embeddings} = memory} ->
            score = AI.Util.cosine_similarity(needle, embeddings)
            {memory, score}

          {:error, reason} ->
            UI.error(
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
           updated_at: timestamp
         }}
    end
  end

  @doc """
  Creates a new `Memory` struct from the given map. Expects keys to be atoms.
  Returns a `Memory.t`.
  """
  @spec new_from_map(map) :: t
  def new_from_map(data) do
    %Memory{
      scope: Map.get(data, :scope),
      title: Map.get(data, :title),
      slug: Map.get(data, :slug),
      content: Map.get(data, :content),
      topics: Map.get(data, :topics),
      embeddings: Map.get(data, :embeddings),
      inserted_at: Map.get(data, :inserted_at),
      updated_at: Map.get(data, :updated_at)
    }
  end

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

  @spec save(t) :: {:ok, t} | {:error, term}
  def save(%Memory{} = memory) do
    memory = ensure_timestamps(memory)

    with {:ok, memory} <- ensure_embeddings(memory),
         :ok <- do_save(memory) do
      {:ok, memory}
    end
  end

  @spec forget(t) :: :ok | {:error, term}
  def forget(%{scope: :global, title: title}), do: Memory.Global.forget(title)
  def forget(%{scope: :project, title: title}), do: Memory.Project.forget(title)
  def forget(%{scope: :session, title: title}), do: Memory.Session.forget(title)

  # ----------------------------------------------------------------------------
  # Utilities for implementors
  # ----------------------------------------------------------------------------
  @doc """
  Serializes the given `memory` to a JSON binary.
  """
  @spec marshal(t) :: {:ok, binary} | {:error, term}
  def marshal(%Memory{} = memory) do
    case Jason.encode(memory) do
      {:ok, json} -> {:ok, json}
      error -> error
    end
  end

  @doc """
  Deserializes the given JSON binary to a `Memory` struct.
  """
  @spec unmarshal(binary) :: {:ok, t} | {:error, term}
  def unmarshal(json) when is_binary(json) do
    with {:ok, data} <- Jason.decode(json),
         {:ok, scope_str} <- Map.fetch(data, "scope"),
         scope = String.to_existing_atom(scope_str),
         {:ok, title} <- Map.fetch(data, "title"),
         {:ok, slug} <- Map.fetch(data, "slug"),
         {:ok, content} <- Map.fetch(data, "content"),
         {:ok, topics} <- Map.fetch(data, "topics"),
         {:ok, embeddings} <- Map.fetch(data, "embeddings") do
      {:ok,
       %Memory{
         scope: scope,
         title: title,
         slug: slug,
         content: content,
         topics: topics,
         embeddings: embeddings,
         inserted_at: Map.get(data, "inserted_at"),
         updated_at: Map.get(data, "updated_at")
       }}
    else
      :error -> {:error, :invalid_memory_structure}
      _ -> {:error, :invalid_json_format}
    end
  end

  @doc """
  A title is valid if it is non-empty, does not contain more than one non-word
  character in a row (which would lead to either multiple hyphens in the slug
  or cases where multiple titles map to the same slug), and does not start or
  end with a non-word character.
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

    errors =
      if String.trim(title) == "" do
        ["must not be empty" | errors]
      else
        errors
      end

    errors =
      if String.match?(title, ~r/[^a-zA-Z0-9](?:[^a-zA-Z0-9]|$)/) do
        ["must not contain two non-alphanumeric characters in a row (including spaces)" | errors]
      else
        errors
      end

    errors =
      if String.match?(title, ~r/^(?:[^a-zA-Z0-9]|.*[^a-zA-Z0-9]$)/) do
        ["must start and end with a letter or number" | errors]
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
  def is_unique_title?(scope, title), do: not exists?(scope, title)

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
    if memory.inserted_at in [nil, ""] or memory.updated_at in [nil, ""] do
      case save(memory) do
        {:ok, migrated} ->
          {:ok, migrated}

        {:error, reason} ->
          UI.warn(@log_tag, "Failed to update memory format: #{inspect(reason)}")
          {:ok, memory}
      end
    else
      {:ok, memory}
    end
  end

  defp maybe_migrate_on_read(error), do: error

  # Ensures memory timestamps are set. If inserted_at is missing or empty, uses
  # updated_at. If updated_at is missing or empty, uses the current timestamp.
  defp ensure_timestamps(memory) do
    now =
      DateTime.utc_now()
      |> DateTime.to_iso8601()

    inserted_at =
      [
        memory.inserted_at,
        memory.updated_at
      ]
      |> Enum.find(now, fn
        nil -> false
        "" -> false
        _ -> true
      end)

    updated_at =
      case memory.updated_at do
        nil -> now
        "" -> now
        x -> x
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

  # ----------------------------------------------------------------------------
  # Memory Ingestion
  # ----------------------------------------------------------------------------
  # The number of concurrent ingestion workers.
  @ingestion_concurrency 2

  @doc """
  Spawns a task that performs memory consolidation by ingesting all
  conversations in the current project into long-term memory. Returns `:ok`
  immediately. Ingestion is restricted to `@ingestion_concurrency` workers
  (currently 2).
  """
  @spec perform_memory_consolidation() :: Task.t()
  def perform_memory_consolidation() do
    Services.Globals.Spawn.async(fn ->
      # Use a dedicated HTTP pool for memory ingestion to avoid interfering
      # with other API calls. This pool is scoped to the current process.
      HttpPool.set(:ai_memory)

      UI.begin_step(@log_tag, "Accreting long-term memories from past conversations")

      ingest_all_conversations()
      |> case do
        :ok ->
          UI.end_step_background(@log_tag, "Yum. Tasted like en-graham crackers.")

        {:error, reason} ->
          UI.end_step_background(@log_tag, reason)
      end
    end)
  end

  @doc """
  Ingest all conversations in the current project into long-term memory.
  Conversations that have not changed since their last ingestion are skipped.
  The current conversation (if any) is also skipped.
  """
  @spec ingest_all_conversations() :: :ok | {:error, term}
  def ingest_all_conversations() do
    with {:ok, project} <- Store.get_project() do
      current =
        Services.Globals.get_env(:fnord, :current_conversation, nil)
        |> case do
          nil -> nil
          pid -> Services.Conversation.get_id(pid)
        end

      project
      |> Store.Project.Conversation.list()
      |> Enum.reject(&(&1.id == current))
      |> Util.async_stream(&ingest_conversation/1, max_concurrency: @ingestion_concurrency)
      |> Stream.run()

      :ok
    end
  end

  @doc """
  Ingest a single conversation into long-term memory. Conversations that have
  not changed since their last ingestion are skipped. Conversations that have
  never been ingested are treated as changed, and ingested.
  """
  @spec ingest_conversation(Store.Project.Conversation.t()) :: :ok | {:error, term}
  def ingest_conversation(conversation) do
    with {:ok, data} <- Store.Project.Conversation.read(conversation),
         {:ok, meta} <- Map.fetch(data, :metadata),
         {:ok, msgs} <- Map.fetch(data, :messages) do
      old_hash = Map.get(meta, :long_term_memory_hash, "")
      new_hash = make_hash(msgs)

      if old_hash != new_hash do
        AI.Agent.Memory.Ingest
        |> AI.Agent.new(named?: false)
        |> AI.Agent.get_response(%{messages: msgs})
        |> case do
          {:ok, response} ->
            label = get_label(conversation, response)
            UI.end_step_background(@log_verb, label)

            # Re-read the conversation to ensure no changes occurred during
            # ingestion. For example, in another OS process.
            FileLock.with_lock(conversation.store_path, fn ->
              with {:ok, data} <- Store.Project.Conversation.read(conversation),
                   {:ok, meta} <- Map.fetch(data, :metadata),
                   {:ok, msgs} <- Map.fetch(data, :messages) do
                # If the hash is still different, that means another process
                # modified the conversation during ingestion. In that case, we
                # skip updating the hash, because there are now new messages
                # that must be considered for long-term memory.
                if new_hash == make_hash(msgs) do
                  meta = Map.put(meta, :long_term_memory_hash, new_hash)
                  data = Map.put(data, :metadata, meta)
                  Store.Project.Conversation.write(conversation, data)
                end
              end
            end)

          {:error, reason} ->
            {:error, reason}
        end
        |> case do
          {:ok, {:ok, _result}} -> :ok
          {:ok, {:error, reason}} -> {:error, reason}
          {:ok, nil} -> :ok
          {:error, reason} -> {:error, reason}
        end
      else
        :ok
      end
    end
  end

  defp make_hash(msgs) do
    msgs
    |> Jason.encode!()
    |> :erlang.md5()
    |> Base.encode16()
  end

  defp get_label(_conversation, response) do
    cols = Owl.IO.columns() || 120
    prefix_len = String.length("[info] ✓ #{@log_verb}: [xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx] ")
    min_width = 20
    width = max(cols - prefix_len, min_width)

    response
    |> String.split("\n")
    |> List.first()
    |> String.trim()
    # If the line is long, truncate and add ellipsis
    |> then(fn line ->
      line
      |> Owl.Data.tag([:italic, :light_black])
      |> Owl.Data.truncate(width)
      |> Owl.Data.to_chardata()
      |> to_string()
    end)
  end
end

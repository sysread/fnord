defmodule Store.Project.Conversation do
  @moduledoc """
  Conversations are stored per project under `conversations/` in the project
  store.

  The canonical on-disk shape is a v1 JSON object written by
  `Store.Project.Conversation.Format`. That payload includes:

  - `version`
  - `timestamp`
  - `messages`
  - `metadata`
  - `memory`
  - `tasks`

  Legacy v0 timestamp-prefixed files are still readable, but new writes go out
  through the v1 format path.

  Existing conversations are retrieved by their UUID identifier.
  """

  defstruct [
    :project_home,
    :store_path,
    :id
  ]

  @type t :: %__MODULE__{}

  @type data :: %{
          timestamp: DateTime.t(),
          messages: AI.Util.msg_list(),
          metadata: map,
          memory: list,
          tasks: %{binary => %{description: binary | nil, tasks: Services.Task.task_list()}}
        }

  @store_dir "conversations"

  @doc """
  Lists all conversations in the given project in ascending order by timestamp.
  """
  @spec list(Store.Project.t()) :: [t]
  def list(%Store.Project{store_path: store_path}), do: list(store_path)

  @spec list(binary) :: [t]
  def list(project_home) do
    project_home
    |> Path.join(["conversations/*.json"])
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".json"))
    |> Enum.map(&Store.Project.Conversation.new(&1, project_home))
    |> Enum.sort_by(
      fn conv ->
        case Store.Project.Conversation.timestamp(conv) do
          %DateTime{} = dt -> DateTime.to_unix(dt)
          int when is_integer(int) -> int
        end
      end,
      :asc
    )
  end

  @doc """
  Create a new conversation with a new UUID identifier and the globally
  selected project.
  """
  def new do
    with {:ok, project} <- Store.get_project() do
      new(Uniq.UUID.uuid4(), project.store_path)
    else
      {:error, _} -> raise "No project selected"
    end
  end

  @doc """
  Create a new conversation from an existing UUID identifier and the globally
  selected project.
  """
  def new(id) do
    with {:ok, project} <- Store.get_project() do
      new(id, project.store_path)
    else
      {:error, _} -> raise "No project selected"
    end
  end

  @doc """
  Create a new conversation from an existing UUID identifier and an explicitly
  specified project.
  """
  def new(id, project_home) when is_binary(project_home) do
    %__MODULE__{
      project_home: project_home,
      store_path: build_store_path(project_home, id),
      id: id
    }
  end

  def new(id, %Store.Project{store_path: store_path}) do
    new(id, store_path)
  end

  @doc """
  Returns true if the conversation exists on disk, false otherwise.
  """
  @spec exists?(t) :: boolean()
  def exists?(%__MODULE__{store_path: store_path}) do
    File.exists?(store_path)
  end

  @doc """
  Saves the conversation in the store.

  New conversations get a fresh timestamp and default empty fields for
  `messages`, `metadata`, `memory`, and `tasks`.

  Existing conversations are read first so the stored `messages`, `metadata`,
  `memory`, and `tasks` can be merged with the incoming data. The timestamp is
  reused when the merged message list is unchanged; otherwise a fresh timestamp
  is written.
  """
  @spec write(t, map) :: {:ok, t} | {:error, any()}
  def write(conversation, data \\ %{}) do
    # Ensure the project store directory exists
    conversation.project_home
    |> build_store_dir()
    |> File.mkdir_p()

    {timestamp, final_data} =
      if exists?(conversation) do
        case read(conversation) do
          {:ok, existing} ->
            # Prepare existing fields for merge
            existing_data = %{
              messages: existing.messages,
              metadata: existing.metadata,
              memory: existing.memory,
              tasks: existing.tasks
            }

            # Merge incoming data over existing data
            merged = Map.merge(existing_data, data)

            # Normalize incoming messages (string vs atom keys) before comparing
            merged_messages =
              merged
              |> Map.get(:messages, [])
              |> Util.string_keys_to_atoms()

            merged = Map.put(merged, :messages, merged_messages)

            # Reuse timestamp if messages unchanged
            existing_msgs = existing_data.messages

            timestamp =
              if merged_messages == existing_msgs do
                DateTime.to_unix(existing.timestamp)
              else
                marshal_ts()
              end

            {timestamp, merged}

          _ ->
            # Unable to read existing; treat as new
            ts = marshal_ts()

            new_data =
              data
              |> Map.put_new(:messages, [])
              |> Map.put_new(:metadata, %{})
              |> Map.put_new(:memory, [])
              |> Map.put_new(:tasks, %{})

            {ts, new_data}
        end
      else
        # New conversation
        ts = marshal_ts()

        new_data =
          data
          |> Map.put_new(:messages, [])
          |> Map.put_new(:metadata, %{})
          |> Map.put_new(:memory, [])
          |> Map.put_new(:tasks, %{})

        {ts, new_data}
      end

    # Persist task list descriptions alongside tasks: normalize to new shape
    normalized =
      final_data
      |> Map.update(:tasks, %{}, fn tasks_map ->
        tasks_map
        |> Enum.map(fn {list_id, raw} ->
          {items, desc} =
            cond do
              is_list(raw) ->
                # Legacy list shape: bare list of tasks, no description
                {raw, nil}

              is_map(raw) and Map.has_key?(raw, :tasks) ->
                # New shape: map with :tasks and :description
                {Map.get(raw, :tasks), Map.get(raw, :description)}

              true ->
                {[], nil}
            end

          {list_id, %{tasks: items, description: desc}}
        end)
        |> Map.new()
      end)

    # Persist as v1 (pure JSON with `version: 1` and top-level `timestamp`).
    # See Store.Project.Conversation.Format for the on-disk format rationale
    # and the cross-worktree migration story.
    with :ok <- Store.Project.Conversation.Format.write(conversation, normalized, timestamp) do
      {:ok, conversation}
    end
  end

  @doc """
  Reads the conversation from the store.

  Returns the canonical conversation map with `timestamp`, `messages`,
  `metadata`, `memory`, and `tasks`.

  Delegates to `Store.Project.Conversation.Format.read/1`, which transparently
  handles both v0 (legacy timestamp-prefixed) and v1 (pure JSON with
  `version: 1`) file shapes. See that module for the cross-worktree migration
  strategy.
  """
  @spec read(t) :: {:ok, data} | {:error, any}
  def read(conversation) do
    Store.Project.Conversation.Format.read(conversation)
  end

  @doc """
  Forks the given conversation, returning a new conversation with a new UUID
  and identical messages. Saves the forked conversation to disk with the
  current timestamp.
  """
  @spec fork(t) :: {:ok, t} | {:error, any}
  def fork(conversation) do
    with {:ok, data} <- read(conversation) do
      # Mark all existing session memories as :ignore so the indexer won't
      # re-process them in the forked conversation. They remain visible to
      # the LLM for context but won't generate duplicate long-term memories.
      forked_memory =
        Enum.map(data.memory, fn
          %Memory{scope: :session} = m -> %{m | index_status: :ignore}
          other -> other
        end)

      with {:ok, forked} <- write(new(), %{data | memory: forked_memory}) do
        {:ok, forked}
      end
    end
  end

  @doc """
  Returns the timestamp of the conversation. If the conversation has not yet
  been saved to the store, returns 0. v0 files yield their timestamp from the
  numeric prefix (cheap); v1 files require a full JSON decode (paid once a
  v1 file is encountered).
  """
  @spec timestamp(t) :: DateTime.t() | 0
  def timestamp(conversation) do
    if exists?(conversation) do
      with {:ok, contents} <- File.read(conversation.store_path),
           {:ok, ts} <- Store.Project.Conversation.Format.timestamp_of(contents) do
        ts
      else
        _ -> 0
      end
    else
      0
    end
  end

  @doc """
  Returns the user's prompting message in the conversation. This is considered
  to be the first "user" role message in the conversation.
  """
  @spec question(t) :: {:ok, binary} | {:error, :no_question}
  def question(conversation) do
    case read(conversation) do
      {:ok, data} ->
        case Enum.find(data.messages, &(Map.get(&1, :role) == "user")) do
          nil -> {:error, :no_question}
          msg -> Map.fetch(msg, :content)
        end

      _ ->
        {:error, :no_question}
    end
  end

  @doc """
  Returns the number of messages in the conversation. If the conversation does
  not exist, returns 0.
  """
  @spec num_messages(t) :: non_neg_integer()
  def num_messages(conversation) do
    case read(conversation) do
      {:ok, data} -> length(data.messages)
      _ -> 0
    end
  end

  @doc """
  Deletes the conversation from the store. If the conversation does not exist,
  returns an error tuple.
  """
  @spec delete(t) :: :ok | {:error, :not_found}
  def delete(conversation) do
    if exists?(conversation) do
      File.rm!(conversation.store_path)
      :ok
    else
      {:error, :not_found}
    end
  end

  # -----------------------------------------------------------------------------
  # Private functions
  # -----------------------------------------------------------------------------
  @spec build_store_dir(binary) :: binary
  defp build_store_dir(project_home) do
    Path.join([project_home, @store_dir])
  end

  @spec build_store_path(binary, binary) :: binary
  defp build_store_path(project_home, id) do
    file = build_store_dir(project_home) |> Path.join(id)
    file <> ".json"
  end

  defp marshal_ts() do
    DateTime.utc_now()
    |> DateTime.to_unix()
  end
end

defmodule Store.Project.Conversation do
  @moduledoc """
  Conversations are stored per project in the project's store dir, under
  `converations/`. Each file is *mostly* JSON, but with a timestamp prepended
  to the JSON data, separated by a colon. This allows for easy sorting, without
  having to parse dozens or hundreds of messages for each file.

  The JSON object currently has the following keys:
  - `messages`: a list of messages in the conversation
  - `metadata`: a map of metadata for the conversation
  - `memory`: a list of memory objects associated with the conversation

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

  For new conversations, generates a fresh timestamp.
  For existing conversations, only updates the on-disk timestamp if the conversation's messages have changed;
  otherwise reuses the existing timestamp. Incoming data is merged with existing conversation data so
  that missing keys fallback to the existing values.
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

    # Encode and write JSON with timestamp prefix
    with {:ok, json} <- Jason.encode(normalized),
         :ok <- File.write(conversation.store_path, "#{timestamp}:" <> json) do
      {:ok, conversation}
    end
  end

  @doc """
  Reads the conversation from the store. Returns a map with the timestamp,
  messages, metadata, and memory in the conversation.
  """
  @spec read(t) :: {:ok, data} | {:error, any}
  def read(conversation) do
    with {:ok, contents} <- File.read(conversation.store_path),
         [timestamp_str, json] <- String.split(contents, ":", parts: 2),
         {:ok, timestamp} <- unmarshal_ts(timestamp_str),
         {:ok, data} <- Jason.decode(json) do
      msgs =
        data
        |> Map.get("messages", [])
        |> Util.string_keys_to_atoms()

      metadata =
        data
        |> Map.get("metadata", %{})
        |> Util.string_keys_to_atoms()

      memories =
        data
        |> Map.get("memory", [])
        |> Util.string_keys_to_atoms()
        |> Enum.map(&Memory.new_from_map/1)

      tasks =
        data
        |> Map.get("tasks", %{})
        |> Enum.map(fn {list_id, value} ->
          # Normalize to %{tasks: [...], description: ...} format
          {raw_tasks, desc} =
            cond do
              is_list(value) ->
                # Legacy format: bare list of tasks
                {value, nil}

              is_map(value) ->
                # New format: map with tasks and description
                val = Util.string_keys_to_atoms(value)
                {Map.get(val, :tasks, []), Map.get(val, :description)}

              true ->
                # Invalid/empty
                {[], nil}
            end

          # Parse tasks with outcome normalization
          tasks_list =
            raw_tasks
            |> Util.string_keys_to_atoms()
            |> Enum.map(fn %{id: task_id, data: data} = task_data ->
              opts =
                task_data
                |> Map.drop([:id, :data])
                |> Keyword.new()

              # Normalize outcome using shared utility
              opts =
                case Keyword.get(opts, :outcome) do
                  outcome when not is_nil(outcome) ->
                    Keyword.put(opts, :outcome, Services.Task.Util.normalize_outcome(outcome))

                  _ ->
                    opts
                end

              Services.Task.new_task(task_id, data, opts)
            end)

          {list_id, %{description: desc, tasks: tasks_list}}
        end)
        |> Map.new()

      {:ok,
       %{
         timestamp: timestamp,
         messages: msgs,
         metadata: metadata,
         memory: memories,
         tasks: tasks
       }}
    end
  end

  @doc """
  Forks the given conversation, returning a new conversation with a new UUID
  and identical messages. Saves the forked conversation to disk with the
  current timestamp.
  """
  @spec fork(t) :: {:ok, t} | {:error, any}
  def fork(conversation) do
    with {:ok, data} <- read(conversation),
         {:ok, forked} <- write(new(), data) do
      {:ok, forked}
    end
  end

  @doc """
  Returns the timestamp of the conversation. If the conversation has not yet
  been saved to the store, returns 0.
  """
  @spec timestamp(t) :: DateTime.t() | 0
  def timestamp(conversation) do
    if exists?(conversation) do
      with {:ok, contents} <- File.read(conversation.store_path),
           [timestamp, _] <- String.split(contents, ":", parts: 2),
           {:ok, timestamp} <- timestamp |> String.to_integer() |> DateTime.from_unix() do
        timestamp
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

  defp unmarshal_ts(numerical_string) do
    numerical_string
    |> String.to_integer()
    |> DateTime.from_unix()
  end

  defp marshal_ts() do
    DateTime.utc_now()
    |> DateTime.to_unix()
  end
end

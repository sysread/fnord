defmodule Store.Project.Conversation do
  @moduledoc """
  Conversations are stored per project in the project's store dir, under
  `converations/`. Each conversation is given a UUID identifier and stored as a
  JSON file with the keys:
    - `messages`: a list of messages in the conversation
    - `timestamp`: the time the conversation was last written to

  Existing conversations are retrieved by their UUID identifier.
  """

  defstruct [
    :project,
    :store_path,
    :id
  ]

  @store_dir "conversations"

  @doc """
  Create a new conversation with a new UUID identifier and the globally
  selected project.
  """
  def new(), do: new(Uniq.UUID.uuid4(), Store.get_project())

  @doc """
  Create a new conversation from an existing UUID identifier and the globally
  selected project.
  """
  def(new(id), do: new(id, Store.get_project()))

  @doc """
  Create a new conversation from an existing UUID identifier and an explicitly
  specified project.
  """
  def new(id, project) do
    %__MODULE__{
      project: project,
      store_path: build_store_path(project, id),
      id: id
    }
  end

  @doc """
  Returns true if the conversation exists on disk, false otherwise.
  """
  def exists?(conversation) do
    File.exists?(conversation.store_path)
  end

  @doc """
  Saves the conversation in the store. The conversation's timestamp is updated
  to the current time.
  """
  def write(conversation, messages) do
    conversation.project
    |> build_store_dir()
    |> File.mkdir_p()

    timestamp =
      DateTime.utc_now()
      |> DateTime.to_unix()

    data = %{messages: messages}

    with {:ok, json} <- Jason.encode(data),
         :ok <- File.write(conversation.store_path, "#{timestamp}:#{json}") do
      {:ok, conversation}
    end
  end

  @doc """
  Reads the conversation from the store. Returns a tuple with the timestamp and
  the messages in the conversation.
  """
  def read(conversation) do
    with {:ok, contents} <- File.read(conversation.store_path),
         [timestamp, json] <- String.split(contents, ":", parts: 2),
         {:ok, timestamp} <- timestamp |> String.to_integer() |> DateTime.from_unix(),
         {:ok, %{"messages" => msgs}} <- Jason.decode(json) do
      {:ok, timestamp, Util.string_keys_to_atoms(msgs)}
    end
  end

  @doc """
  Returns the timestamp of the conversation. If the conversation has not yet
  been saved to the store, returns 0.
  """
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
  def question(conversation) do
    with {:ok, _, msgs} <- read(conversation) do
      msgs
      |> Enum.find(&(Map.get(&1, :role) == "user"))
      |> case do
        nil -> {:error, :no_question}
        msg -> Map.fetch(msg, :content)
      end
    end
  end

  @doc """
  Deletes the conversation from the store. If the conversation does not exist,
  returns an error tuple.
  """
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
  defp build_store_dir(project) do
    Path.join([project.store_path, @store_dir])
  end

  defp build_store_path(project, id) do
    file = build_store_dir(project) |> Path.join(id)
    file <> ".json"
  end
end

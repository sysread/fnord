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
    :project_home,
    :store_path,
    :id
  ]

  @type t :: %__MODULE__{}

  @store_dir "conversations"

  @doc """
  Lists all conversations in the given project.
  """
  @spec list(String.t()) :: [t()]
  def list(project_home) do
    conversations =
      project_home
      |> Path.join(["conversations/*.json"])
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".json"))
      |> Enum.map(&Store.Project.Conversation.new(&1, project_home))

    timestamps =
      conversations
      |> Enum.reduce(%{}, fn conversation, acc ->
        timestamp = Store.Project.Conversation.timestamp(conversation)
        Map.put(acc, conversation.id, timestamp)
      end)

    conversations
    |> Enum.sort(fn a, b -> timestamps[a.id] > timestamps[b.id] end)
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
  @spec exists?(t()) :: boolean()
  def exists?(conversation) do
    File.exists?(conversation.store_path)
  end

  @doc """
  Saves the conversation in the store. The conversation's timestamp is updated
  to the current time.
  """
  @spec write(t(), list()) :: {:ok, t()} | {:error, any()}
  def write(conversation, messages) do
    conversation.project_home
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
  @spec read(t()) :: {:ok, DateTime.t(), list()} | {:error, any()}
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
  @spec timestamp(t()) :: DateTime.t() | 0
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
  @spec question(t()) :: {:ok, String.t()} | {:error, :no_question}
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
  @spec delete(t()) :: :ok | {:error, :not_found}
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
  @spec build_store_dir(String.t()) :: String.t()
  defp build_store_dir(project_home) do
    Path.join([project_home, @store_dir])
  end

  @spec build_store_path(String.t(), String.t()) :: String.t()
  defp build_store_path(project_home, id) do
    file = build_store_dir(project_home) |> Path.join(id)
    file <> ".json"
  end
end

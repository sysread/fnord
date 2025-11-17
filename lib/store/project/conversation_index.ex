defmodule Store.Project.ConversationIndex do
  @moduledoc """
  Manages semantic index data for conversations within a project.

  Index data is stored under the project's store path in a parallel
  directory tree to conversations themselves:

      <store_path>/conversations/index/<conversation-id>/
        embeddings.json
        metadata.json

  This module is responsible for tracking which conversations are indexed,
  determining which ones are new or stale, and reading/writing embeddings
  and associated metadata.
  """

  alias Store.Project
  alias Store.Project.Conversation

  @type metadata :: %{
          optional(String.t()) => any
        }

  @type status :: %{
          new: [Conversation.t()],
          stale: [Conversation.t()],
          deleted: [String.t()]
        }

  @index_dir "conversations/index"
  @embeddings_filename "embeddings.json"
  @metadata_filename "metadata.json"

  @spec root(Project.t()) :: String.t()
  def root(%Project{store_path: store_path}) do
    Path.join(store_path, @index_dir)
  end

  @spec path_for(Project.t(), String.t()) :: String.t()
  def path_for(project, conversation_id) do
    project
    |> root()
    |> Path.join(conversation_id)
  end

  @doc """
  Returns the status of the conversation index for the given project.

  It classifies conversations into:
    * `:deleted`  - indexed conversations whose source conversation no longer exists
    * `:stale`    - conversations whose index metadata is stale compared to the
                    on-disk conversation timestamp or embedding model
    * `:new`      - conversations that exist but have no index entry
  """
  @spec index_status(Project.t()) :: status
  def index_status(%Project{} = project) do
    source_conversations = Conversation.list(project.store_path)

    indexed_conversations =
      project
      |> root()
      |> Path.join("*/#{@metadata_filename}")
      |> Path.wildcard()
      |> Enum.map(&Path.dirname/1)
      |> Enum.map(&Path.basename/1)

    source_by_id = Map.new(source_conversations, &{&1.id, &1})
    indexed_ids = MapSet.new(indexed_conversations)
    source_ids = MapSet.new(Map.keys(source_by_id))

    new_ids = MapSet.difference(source_ids, indexed_ids)
    deleted_ids = MapSet.difference(indexed_ids, source_ids)

    stale_convs =
      source_conversations
      |> Enum.filter(fn convo ->
        case read_metadata(project, convo.id) do
          {:ok, %{"last_indexed_ts" => ts}} ->
            case Conversation.timestamp(convo) do
              # 0 means unsaved and is treated as stale via `int > ts` logic
              %DateTime{} = dt -> DateTime.to_unix(dt) > ts
              int when is_integer(int) -> int > ts
            end

          _ ->
            # If we cannot read metadata, treat as stale so it will be reindexed.
            true
        end
      end)
      |> Enum.reject(fn convo -> not MapSet.member?(indexed_ids, convo.id) end)

    %{
      new:
        new_ids
        |> Enum.map(&Map.fetch!(source_by_id, &1)),
      stale: stale_convs,
      deleted: MapSet.to_list(deleted_ids)
    }
  end

  @doc """
  Writes embeddings and metadata for a conversation.

  The embeddings are stored in `embeddings.json` and the metadata in
  `metadata.json` under the conversation's index directory.
  """
  @spec write_embeddings(Project.t(), String.t(), any, metadata) :: :ok | {:error, term}
  def write_embeddings(%Project{} = project, conversation_id, embeddings, metadata) do
    dir = path_for(project, conversation_id)

    with :ok <- File.mkdir_p(dir),
         :ok <- write_json(Path.join(dir, @embeddings_filename), embeddings),
         :ok <- write_json(Path.join(dir, @metadata_filename), metadata) do
      :ok
    end
  end

  @doc """
  Reads embeddings and metadata for a conversation.

  Returns `{:ok, %{embeddings: embeddings, metadata: metadata}}` on success
  or an error tuple if either file cannot be read/decoded.
  """
  @spec read_embeddings(Project.t(), String.t()) ::
          {:ok, %{embeddings: any, metadata: metadata}} | {:error, term}
  def read_embeddings(%Project{} = project, conversation_id) do
    dir = path_for(project, conversation_id)
    embeddings_path = Path.join(dir, @embeddings_filename)
    metadata_path = Path.join(dir, @metadata_filename)

    with {:ok, embeddings} <- read_json(embeddings_path),
         {:ok, metadata} <- read_json(metadata_path) do
      {:ok, %{embeddings: embeddings, metadata: metadata}}
    end
  end

  @doc """
  Reads only the metadata for a conversation index entry.
  """
  @spec read_metadata(Project.t(), String.t()) :: {:ok, metadata} | {:error, term}
  def read_metadata(%Project{} = project, conversation_id) do
    dir = path_for(project, conversation_id)
    metadata_path = Path.join(dir, @metadata_filename)

    read_json(metadata_path)
  end

  @doc """
  Enumerates all indexed conversations, yielding `{id, embedding_vector, metadata}`.
  """
  @spec all_embeddings(Project.t()) :: Enumerable.t()
  def all_embeddings(%Project{} = project) do
    project
    |> root()
    |> Path.join("*/#{@embeddings_filename}")
    |> Path.wildcard()
    |> Stream.map(fn path ->
      id =
        path
        |> Path.dirname()
        |> Path.basename()

      embeddings_result = read_json(path)
      metadata_result = read_metadata(project, id)

      case {embeddings_result, metadata_result} do
        {{:ok, embeddings}, {:ok, metadata}} -> {id, embeddings, metadata}
        _ -> nil
      end
    end)
    |> Stream.reject(&is_nil/1)
  end

  @doc """
  Deletes the index entry for the given conversation id.
  """
  @spec delete(Project.t(), String.t()) :: :ok
  def delete(%Project{} = project, conversation_id) do
    project
    |> path_for(conversation_id)
    |> File.rm_rf!()

    :ok
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  @spec write_json(String.t(), any) :: :ok | {:error, term}
  defp write_json(path, data) do
    case Jason.encode(data) do
      {:ok, json} -> File.write(path, json)
      error -> error
    end
  end

  @spec read_json(String.t()) :: {:ok, any} | {:error, term}
  defp read_json(path) do
    case File.read(path) do
      {:ok, contents} -> Jason.decode(contents)
      error -> error
    end
  end
end

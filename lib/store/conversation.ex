defmodule Store.Conversation do
  defstruct [
    :project,
    :store_path,
    :id
  ]

  @store_dir "conversations"

  def new() do
    UUID.uuid4() |> new(Store.get_project())
  end

  def new(id) do
    id |> new(Store.get_project())
  end

  def new(id, project) do
    %__MODULE__{
      project: project,
      store_path: build_store_path(project, id),
      id: id
    }
  end

  def name(conversation) do
    conversation.store_path
    |> Path.basename()
    |> String.replace(".json", "")
  end

  def exists?(conversation) do
    File.exists?(conversation.store_path)
  end

  def write(conversation, agent, messages) do
    conversation.project
    |> build_store_dir()
    |> File.mkdir_p()

    timestamp =
      DateTime.utc_now()
      |> DateTime.to_unix()

    data = %{
      agent: inspect(agent),
      messages: messages
    }

    with {:ok, json} <- Jason.encode(data),
         :ok <- File.write(conversation.store_path, "#{timestamp}:#{json}") do
      {:ok, conversation}
    end
  end

  def read(conversation) do
    with {:ok, contents} <- File.read(conversation.store_path),
         [timestamp, json] <- String.split(contents, ":", parts: 2),
         {:ok, timestamp} <- timestamp |> String.to_integer() |> DateTime.from_unix(),
         {:ok, data} <- Jason.decode(json) do
      {:ok, timestamp, data}
    end
  end

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

  def question(conversation) do
    with {:ok, _, data} <- read(conversation),
         {:ok, messages} <- Map.fetch(data, "messages") do
      messages
      |> Enum.find(&(Map.get(&1, "role") == "user"))
      |> Map.get("content")
      |> then(&{:ok, &1})
    end
  end

  defp build_store_dir(project) do
    Path.join([project.store_path, @store_dir])
  end

  defp build_store_path(project, id) do
    file = build_store_dir(project) |> Path.join(id)
    file <> ".json"
  end
end

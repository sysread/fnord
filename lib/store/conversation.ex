defmodule Store.Conversation do
  defstruct [
    :project,
    :store_path,
    :id
  ]

  @store_dir "conversations"
  @id_format "%Y%m%d.%H%M%S.%f"

  def new() do
    new(new_id(), Store.get_project())
  end

  def new(id, project) do
    %__MODULE__{
      project: project,
      store_path: build_store_path(project, id),
      id: id
    }
  end

  def exists?(conversation) do
    File.exists?(conversation.store_path)
  end

  def read(conversation) do
    with {:ok, json} <- File.read(conversation.store_path),
         {:ok, data} <- Jason.decode(json) do
      {:ok, data}
    end
  end

  def write(conversation, agent, messages) do
    conversation.project
    |> build_store_dir()
    |> File.mkdir_p()

    data = %{agent: inspect(agent), messages: messages}

    with {:ok, json} <- Jason.encode(data),
         :ok <- File.write(conversation.store_path, json) do
      UI.info("Saved conversation (#{conversation.id}) to #{conversation.store_path}")
    else
      error ->
        UI.error(
          "Failed to save conversation (#{conversation.id}) to #{conversation.store_path}:\n\n#{inspect(error)}"
        )

        error
    end
  end

  defp new_id() do
    DateTime.utc_now() |> Calendar.strftime(@id_format)
  end

  defp build_store_dir(project) do
    Path.join([project.store_path, @store_dir])
  end

  defp build_store_path(project, id) do
    file = build_store_dir(project) |> Path.join(id)
    file <> ".json"
  end
end

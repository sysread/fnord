defmodule Store.DefaultProject do
  def store_path do
    path = Store.store_home() |> Path.join("default")
    if !File.exists?(path), do: File.mkdir_p!(path)
    path
  end

  # -----------------------------------------------------------------------------
  # Conversation
  # - monolithic conversation
  # - floating window of messages
  # - system messages added on demand, not stored in file
  # -----------------------------------------------------------------------------
  @conversation_file "conversation.json"

  def conversation_path do
    path = store_path() |> Path.join(@conversation_file)
    if !File.exists?(path), do: File.write!(path, "[]")
    path
  end

  def read_conversation do
    with {:ok, json} <- conversation_path() |> File.read(),
         {:ok, messages} <- Jason.decode(json) do
      {:ok, Util.string_keys_to_atoms(messages)}
    end
  end

  def write_conversation(messages) do
    messages
    |> Enum.filter(fn %{role: role} -> role in ["user", "assistant", "tool"] end)
    |> Jason.encode()
    |> case do
      {:ok, json} -> File.write(conversation_path(), json)
      error -> error
    end
  end

  # -----------------------------------------------------------------------------
  # Private functions
  # -----------------------------------------------------------------------------
end

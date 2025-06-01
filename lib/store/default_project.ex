defmodule Store.DefaultProject do
  def store_path do
    Store.store_home()
    |> Path.join("default")
    |> ensure_dir!()
  end

  # -----------------------------------------------------------------------------
  # Conversation
  # - monolithic conversation
  # - floating window of messages
  # - system messages added on demand, not stored in file
  # -----------------------------------------------------------------------------
  @conversation_file "conversation.json"

  def conversation_path do
    store_path()
    |> Path.join(@conversation_file)
    |> ensure_file!("[]")
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
  # Evolving prompt
  # -----------------------------------------------------------------------------
  @prompt_file "prompt.md"

  @initial_prompt """
  You are a helpful assistant.
  """

  def prompt_path do
    store_path()
    |> Path.join(@prompt_file)
    |> ensure_file!(@initial_prompt)
  end

  def read_prompt do
    prompt_path()
    |> File.read()
    |> case do
      {:ok, text} -> {:ok, clean_prompt(text)}
      other -> other
    end
  end

  def write_prompt(new_text) do
    cleaned = clean_prompt(new_text)
    File.write(prompt_path(), cleaned)
  end

  def append_prompt(new_text) do
    with {:ok, prompt} <- read_prompt() do
      write_prompt("#{prompt}\n#{new_text}")
    end
  end

  def modify_prompt(needle, replacement) do
    with {:ok, prompt} <- read_prompt() do
      if String.contains?(prompt, needle) do
        prompt
        |> String.replace(needle, replacement, global: false)
        |> write_prompt()
      else
        {:error, "Text not found in prompt: #{needle}"}
      end
    end
  end

  defp clean_prompt(prompt) do
    prompt
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  # -----------------------------------------------------------------------------
  # Notes
  # -----------------------------------------------------------------------------
  @notes_file "notes.md"

  def notes_path do
    store_path()
    |> Path.join(@notes_file)
    |> ensure_file!("# Notes")
  end

  # -----------------------------------------------------------------------------
  # Private functions
  # -----------------------------------------------------------------------------
  defp ensure_dir!(path) do
    if !File.dir?(path) do
      File.mkdir_p!(path)
    end

    path
  end

  defp ensure_file!(path, initial_contents) do
    if !File.exists?(path), do: File.write!(path, initial_contents || "")
    path
  end
end

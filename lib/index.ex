defmodule Index do
  defstruct [:store, :ai]

  def run(root, project, force_reindex) do
    idx = %Index{
      store: Store.new(project),
      ai: AI.new()
    }

    if force_reindex do
      Store.delete_project(idx.store)
    end

    Queue.start_link(4, fn file ->
      IO.write(".")
      process_file(idx, file)
      IO.write(".")
    end)

    Scanner.scan(root, fn file -> Queue.queue(file) end)
    |> case do
      {:error, reason} -> IO.puts("Error: #{reason}")
      _ -> :ok
    end

    Queue.shutdown()
    Queue.join()

    IO.puts("done!")
  end

  def delete_project(project) do
    store = Store.new(project)
    Store.delete_project(store)
  end

  defp process_file(idx, file) do
    existing_hash = Store.get_hash(idx.store, file)
    file_hash = sha256(file)

    if is_nil(existing_hash) or existing_hash != file_hash do
      file_contents = File.read!(file)

      {:ok, summary} = AI.get_summary(idx.ai, file, file_contents)

      to_embed = """
        # File
        `#{file}`

        ## Summary
        #{summary}

        ## Contents
        ```
        #{file_contents}
        ```
      """

      {:ok, embeddings} = AI.get_embeddings(idx.ai, to_embed)

      Store.put(idx.store, file, file_hash, summary, embeddings)
    end
  end

  defp sha256(file_path) do
    case File.read(file_path) do
      {:ok, content} -> :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
      {:error, reason} -> {:error, reason}
    end
  end
end

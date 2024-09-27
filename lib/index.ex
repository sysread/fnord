defmodule Index do
  def run(app) do
    {:ok, pool} =
      Queue.new(4, fn file ->
        IO.write(".")
        process_file(app, file)
        IO.write(".")
      end)

    Scanner.scan(app.root, fn file -> Queue.queue_task(pool, file) end)
    |> case do
      {:error, reason} -> IO.puts("Error: #{reason}")
      _ -> :ok
    end

    Queue.close_and_wait(pool)

    IO.puts("done!")
  end

  defp process_file(app, file) do
    existing_hash = Store.get_hash(app.store, file)
    file_hash = sha256(file)

    if is_nil(existing_hash) or existing_hash != file_hash do
      file_contents = File.read!(file)

      {:ok, summary} = AI.get_summary(app.ai, file, file_contents)

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

      {:ok, embeddings} = AI.get_embeddings(app.ai, to_embed)

      Store.put(app.store, file, file_hash, summary, embeddings)
    end
  end

  defp sha256(file_path) do
    case File.read(file_path) do
      {:ok, content} -> :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
      {:error, reason} -> {:error, reason}
    end
  end
end
